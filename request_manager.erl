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
    {reply, {ok,Ref}, Tab};

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
    case lookup_pid(Tab, OldPid) of
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
                    case reconnect_target(Tab, Target, OldPid) of
                        {error,Reason} -> {stop,Reason,Tab};
                        {ok,_NewPid} -> {noreply,Tab}
                    end
            end;
        {_,_,_Ref} ->
            %% if Req is not null, then it was not closed by outbound
            {stop,internal_error,Tab}
    end;

%% outbound process failed abnormally.
handle_info({'EXIT',OldPid,Reason}, Tab) ->
    case lookup_pid(Tab, OldPid) of
        {_,Target,null} ->
            %% outbound did not even get a chance to fetch a request
            case fail_target(Tab, Target) of
                N when N > ?TARGET_FAIL_MAX ->
                    ets:delete(Tab, {pid,OldPid}),
                    reset_target(Tab, Target, Reason),
                    {noreply,Tab};
                _ ->
                    case reconnect_target(Tab, Target, OldPid) of
                        {error,Reason} -> {stop,Reason,Tab};
                        {ok,_} -> {noreply,Tab}
                    end
            end;
        {_,Target,Ref} ->
            %% stop retrying the request if it keeps failing
            case fail_request(Tab, Ref) of
                N when N > ?REQUEST_FAIL_MAX ->
                    {_,_,_,InPid,_} = lookup_request(Tab, Ref),
                    inbound:fail(InPid, Ref, Reason),
                    ets:delete(Tab, {request,Ref}),
                    ets:delete(Tab, {pid,OldPid});
                _ ->
                    %% reconnect the target and re-insert the request to
                    %% the front of the target's queue
                    case reconnect_target(Tab, Target, OldPid) of
                        {error,Reason} -> {stop,Reason,Tab};
                        {ok,_Pid} -> set_next_request(Tab, Target, Ref)
                    end
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
set_next_request(Tab, Target, Ref) ->
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

reset_target(Tab, Target, Reason) ->
    {_,_,Reqs,_} = lookup_target(Tab, Target),
    foreach(fun (Ref) ->
                    {_,_,_,InPid,_} = lookup_request(Tab, Ref),
                    inbound:fail_request(InPid, Ref, Reason),
                    ets:delete(Tab, {request,Ref})
            end, Reqs),
    ets:update_element({target,Target}, [{2,null},{3,[]}]).

fail_target(Tab, Target) ->
    {_,_,_,Nfail} = lookup_target(Tab, Target),
    ets:update_element(Tab, {target,Target}, {4,Nfail+1}),
    Nfail+1.

fail_request(Tab, Ref) ->
    {_,_,_,_,Nfail} = lookup_request(Tab, Ref),
    ets:update_element(Tab, {request,Ref}, {5,Nfail+1}),
    Nfail+1.

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

reconnect_target(Tab, Target, OldPid) ->
    case apply(outbound, connect, tuple_to_list(Target)) of
        {error,_} = Err -> Err;
        {ok,Pid} ->
            %% do not modify the request queue of the target
            true = ets:update_element(Tab, {target,Target}, {2,Pid}),
            ets:delete(Tab, {pid,OldPid}),
            ets:insert(Tab, {{pid,Pid}, Target, null}),
            {ok,Pid}
    end.
