-module(request_manager).
-behavior(gen_server).

-import(lists, [flatmap/2, reverse/1, foreach/2]).
-include_lib("kernel/include/logger.hrl").
-include("phttp.hrl").

-export([start_link/0, new_request/2, next_request/0, close_request/1]).
-export([cancel_request/1]).

%%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%%% exported interface functions

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], [{debug,[trace]}]).

%%% called by the inbound process

%% Request = {Method, Uri, Headers}
new_request(HostInfo, Request) ->
    gen_server:call(?MODULE, {new_request, HostInfo, Request}).

%%% called by the outbound process

next_request() ->
    gen_server:call(?MODULE, {next_request}).

close_request(Ref) ->
    gen_server:cast(?MODULE, {close_request, self(), Ref}).

cancel_request(Ref) ->
    gen_server:cast(?MODULE, {cancel_request, Ref}).

%%% gen_server callbacks
%%%

init([]) ->
    case application:ensure_all_started(ssl) of
        {ok,_} ->
            process_flag(trap_exit, true),
            Tab = ets:new(?MODULE, [set,private]),
            {ok,Tab};
        {error,Reason} ->
            {stop,Reason}
    end.

handle_call({new_request,Target,Head}, {InPid,_Tag}, Tab) ->
    %% convert data types first so we can fail before opening a socket
    OutPid = connect_target(Tab, Target),
    Ref = insert_request(Tab, {Target,Head,InPid}),
    %% notify outbound there is a request waiting for them
    outbound:new_request(OutPid),
    {reply, Ref, Tab};

handle_call({next_request}, {OutPid,_}, Tab) ->
    {reply, pop_request(Tab, OutPid), Tab}.

%% request is gracefully closed (i.e. finished)
handle_cast({close_request,OutPid,Ref}, Tab) ->
    {_,_,_,InPid,_} = lookup_request(Tab, Ref),
    true = ets:update_element(Tab, {pid,OutPid}, {3,null}),
    ets:delete(Tab, {request,Ref}),
    inbound:close(InPid, Ref),
    {noreply,Tab};

handle_cast({cancel_request,_Ref,_InPid}, Tab) ->
    %% XXX: not yet implemented
    {stop,not_implemented,Tab}.

%% A normal exit can happen if the connection automatically closes when
%% finished.
handle_info({'EXIT',OldPid,normal}, Tab) ->
    T = lookup_pid(Tab, OldPid),
    ets:delete(Tab, {pid,OldPid}),
    case T of
        not_found ->
            {stop,{not_found,OldPid},Tab};
        {_,Target,null} ->
            {_,_,Reqs,_} = lookup_target(Tab, Target),
            %% make sure there are more requests for this target before
            %% reconnecting it
            case Reqs of
                [] ->
                    %% delete target entry so that a new Pid is spawned
                    ets:delete(Tab, {target,Target}),
                    ets:delete(Tab, {pid,OldPid}),
                    {noreply, Tab};
                _ ->
                    case reconnect_target(Tab, Target) of
                        {error,Reason} -> {stop,Reason,Tab};
                        {ok,_NewPid} -> {noreply,Tab}
                    end
            end;
        {_,_,_Ref} ->
            %% if Req is not null, then it was not closed by outbound
            {stop,internal_error,Tab}
    end;

%% outbound process failed abnormally.
%% XXX: this is very similar to the above, but not exactly!
handle_info({'EXIT',OldPid,Reason}, Tab) ->
    {_,Target,Ref} = lookup_pid(Tab, OldPid),
    ets:delete(Tab, {pid,OldPid}),
    A = case Ref of
            null ->
                %% outbound did not even get a chance to send a request
                fail_target(Tab, Target, Reason);
            _ ->
                %% stop retrying the request if it keeps failing
                fail_request(Tab, Ref, Reason)
        end,
    case A of
        fail ->
            {noreply,Tab};
        retry ->
            %% reconnect the target
            ?DBG("handle_info", {retrying,target,Target}),
            case reconnect_target(Tab, Target) of
                {error,Reason} -> {stop,Reason,Tab};
                {ok,_Pid} ->
                    case Ref of
                        null -> ok;
                        %% re-insert the request to the front of the target's
                        %% queue IFF there was a request
                        Ref -> queue_override(Tab, Target, Ref)
                    end,
                    {noreply,Tab}
            end
    end.

%%%
%%% internal utility functions
%%%

%% Requirements:
%%  1. Store new requests {inbound Pid, Head, Ref} so they can be queued and
%%     sent to outbound Pids.
%%  2. Crossref hosts to outbound Pids when deciding whether to spawn a
%%     new outbound Pid or whether to reuse an existing one.
%%  3. Crossref outbound Pids to active requests so that I know which requests
%%     failed, when an outbound Pid exits on error.

%% Record types:
%% 1. {{request,Ref}, Target, Head, InPid, Nfail}
%% 2. {{target,Target}, Pid, Reqs, Nfail}
%% 3. {{pid,Pid}, Target, Req}

lookup(Tab, Key) ->
    case ets:lookup(Tab, Key) of
        [] -> not_found;
        [T] -> T
    end.

lookup_request(Tab, Ref) -> lookup(Tab, {request,Ref}).
lookup_pid(Tab, Pid) -> lookup(Tab, {pid,Pid}).
lookup_target(Tab, Target) -> lookup(Tab, {target,Target}).

%% When a request is added, append it to the Target's request queue.
insert_request(Tab, {Target,Head,InPid}) ->
    Ref = make_ref(),
    ets:insert(Tab, {{request,Ref},Target,Head,InPid,0}),
    {_,_,Reqs,_} = lookup_target(Tab, Target),
    true = ets:update_element(Tab, {target,Target}, {3,[Ref|Reqs]}),
    Ref.

%% Bypass the queue.
queue_override(Tab, Target, Ref) ->
    {_,_,Reqs0,_} = lookup_target(Tab, Target),
    Reqs = reverse([Ref|reverse(Reqs0)]),
    true = ets:update_element(Tab, {target,Target}, {3,Reqs}).

%% Pop a new request from the request queue and associate it with an
%% outbound Pid.
pop_request(Tab, Pid) ->
    {_,Target,_} = lookup_pid(Tab, Pid),
    {_,_,Reqs0,_} = lookup_target(Tab, Target),
    Ref = case Reqs0 of
              [] -> null;
              _ ->
                  [Req|Reqs] = reverse(Reqs0),
                  true = ets:update_element(Tab, {target,Target},
                                            {3, reverse(Reqs)}),
                  Req
          end,
    true = ets:update_element(Tab, {pid,Pid}, {3,Ref}),
    case Ref of
        null -> null;
        _ ->
            {_,_Target,Head,InPid,_} = lookup_request(Tab, Ref),
            {InPid,Ref,Head}
    end.

fail_request(Tab, Ref, Reason) ->
    {_,_,_,InPid,Nfail} = lookup_request(Tab, Ref),
    N = Nfail+1,
    if
        N >= ?REQUEST_FAIL_MAX ->
            inbound:fail(InPid, Ref, Reason),
            ets:delete(Tab, {request,Ref}),
            fail;
        true ->
            ets:update_element(Tab, {request,Ref}, {5,N}),
            retry
    end.

fail_target(Tab, Target, Reason) ->
    {_,_,Reqs,Nfail} = lookup_target(Tab, Target),
    N = Nfail+1,
    if
        N >= ?TARGET_FAIL_MAX ->
            foreach(fun (Ref) ->
                            InPid = element(4, lookup_request(Tab, Ref)),
                            ets:delete(Tab, {request,Ref}),
                            inbound:fail(InPid, Ref, Reason)
                    end, Reqs),
            ets:delete(Tab, {target,Target}),
            fail;
        true ->
            ets:update_element(Tab, {target,Target}, [{2,null},{4,N}]),
            retry
    end.

connect_target(Tab, Target) ->
    case lookup_target(Tab, Target) of
        {_,Pid,_,_} -> Pid;
        not_found ->
            Pid = apply(outbound, connect, tuple_to_list(Target)),
            %% initialize empty request queue
            ets:insert(Tab, {{target,Target}, Pid, [], 0}),
            %% outbound request is null, starts off idle
            ets:insert(Tab, {{pid,Pid}, Target, null}),
            Pid
    end.

reconnect_target(Tab, Target) ->
    Pid = apply(outbound, connect, tuple_to_list(Target)),
    %% do not modify the request queue of the target
    true = ets:update_element(Tab, {target,Target}, {2,Pid}),
    ets:insert(Tab, {{pid,Pid}, Target, null}),
    {ok,Pid}.
