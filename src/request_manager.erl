-module(request_manager).
-behavior(gen_server).

-import(lists, [flatmap/2, reverse/1, foreach/2]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([start/0, start_link/0, stop/0]).
-export([new_request/2, next_request/0, close_request/1]).
-export([cancel_request/1]).

%%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).

%%% exported interface functions

start() ->
    gen_server:start({local,?MODULE}, ?MODULE, [], []).

start_link() ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:stop(?MODULE).

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

terminate(_Reason, Tab) ->
    killout(ets:first(Tab), Tab).

killout('$end_of_table', _) ->
    ok;
killout({pid,Pid}=K, Tab) ->
    exit(Pid, kill),
    killout(ets:next(Tab, K), Tab);
killout(K, Tab) ->
    killout(ets:next(Tab, K), Tab).

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
    true = ets:update_element(Tab, {pid,OutPid}, {3,closed}),
    ets:delete(Tab, {request,Ref}),
    inbound:close(InPid, Ref),
    {noreply,Tab};

%% cancel a request, remove it from the todo list.
handle_cast({cancel_request,_Ref}, Tab) ->
    %% XXX: not yet implemented
    {stop,not_implemented,Tab}.

%% track outbound processes so that was can recreate them if they exit
handle_info({'EXIT',OldPid,Reason1}, Tab) ->
    %%?DBG("handle_info", {'EXIT',OldPid,Reason1}),
    {_,Target,Req} = lookup_pid(Tab, OldPid),
    TargetRec = lookup_target(Tab, Target),
    ReqRec = case Req of
                 null -> null;
                 closed -> null;
                 _ -> lookup_request(Tab, Req)
             end,
    ets:delete(Tab, {pid,OldPid}), % process is gone
    Pending = element(3, TargetRec),
    Task = case fail_task(Reason1, Req, Pending) of
               {target_error,Reason2} ->
                   target_error(Tab, TargetRec, Reason2);
               {request_error,Reason2} ->
                   request_error(Tab, ReqRec, Reason2);
               T -> T
           end,
    %%?DBG("handle_info", {{'EXIT',OldPid,Reason1},{task,Task}}),
    case Task of
        cleanup ->
            %% sanity check
            if
                is_reference(Req) ->
                    ?DBG("handle_info", "cleanup should have no active request!");
                true -> ok
            end,
            ets:delete(Tab, {target,Target});
        {failone,Reason3} ->
            inbound:fail(Req, element(4, ReqRec), Reason3),
            ets:delete(Tab, {request,Req});
        {failall,Reason3} ->
            if
                is_reference(Req) ->
                    inbound:fail(Req, element(4, ReqRec), Reason3),
                    ets:delete(Tab, {request,Req});
                true -> ok
            end,
            foreach(fun ({{request,Ref},_,_,Pid,_}) ->
                            inbound:fail(Pid, Ref, Reason3)
                    end,
                    [lookup_request(Tab, Req_) || Req_ <- element(3, TargetRec)]),
            ets:delete(Tab, {target,Target});
        retry when is_reference(Req) ->
            ok = reconnect_target(Tab, Target, Pending++[Req]);
        retry ->
            ok = reconnect_target(Tab, Target)
    end,
    {noreply,Tab}.

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

%% Pop a new request from the request queue and associate it with an
%% outbound Pid.
pop_request(Tab, Pid) ->
    {_,Target,_} = lookup_pid(Tab, Pid),
    {_,_,Reqs0,_} = lookup_target(Tab, Target),
    case Reqs0 of
        [] -> null;
        _ ->
            [Req|Reqs] = reverse(Reqs0),
            true = ets:update_element(Tab, {target,Target}, {3,reverse(Reqs)}),
            true = ets:update_element(Tab, {pid,Pid}, {3,Req}),
            {_,_Target,Head,InPid,_} = lookup_request(Tab, Req),
            {InPid,Req,Head}
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

%% the request should be 'closed' after outbound calls close_request(Req).

%% No active requests so no big deal, ignore any error.
fail_task(_Reason,closed,[]) ->
    cleanup;

%% This is not supposed to happen. Did we spawn an outbound with no requests?
fail_task(closed,null,[]) ->
    ?DBG("handle_info", "outbound closed with null request"),
    cleanup;

%% Pending requests but server gracefully closed socket.
fail_task(closed,closed,_Pending) ->
    retry;

%% Closed before any request could be queued, not good.
fail_task(closed,null,_Pending) ->
    {target_error,reset};

%% Erro before any request could be queued, not good.
fail_task(Reason,null,_Pending) ->
    {target_error,Reason};

%% Pending requests but some error occurred.
fail_task(Reason,closed,_Pending) ->
    {target_error,Reason};

%% Error or close in the middle of a request/response.
fail_task(Reason,Req,_Pending) when is_reference(Req) ->
    {request_error,Reason}.

request_error(Tab, {{request,Ref},_,_,_,Nfail}, Reason) ->
    N = Nfail+1,
    ?DBG("request_error", {n,N}),
    if
        N >= ?REQUEST_FAIL_MAX ->
            %%ets:delete(Tab, {request,Ref}),
            {failone,Reason};
        true ->
            ets:update_element(Tab, {request,Ref}, {5,N}),
            retry
    end.

target_error(Tab, {{target,Target},_,_,Nfail}, Reason) ->
    N = Nfail+1,
    ?DBG("target_error", {{target,Target},{n,N}}),
    if
        N >= ?TARGET_FAIL_MAX ->
            %%ets:delete(Tab, {target,Target}),
            {failall,Reason};
        true ->
            ets:update_element(Tab, {target,Target}, [{4,N}]),
            retry
    end.

reconnect_target(Tab, Target) ->
    Pid = apply(outbound, connect, tuple_to_list(Target)),
    %% do not modify the request queue of the target
    true = ets:update_element(Tab, {target,Target}, {2,Pid}),
    ets:insert(Tab, {{pid,Pid}, Target, null}),
    ok.

reconnect_target(Tab, Target, Reqs) ->
    ok = reconnect_target(Tab, Target),
    true = ets:update_element(Tab, {target,Target}, {3,Reqs}),
    ok.
