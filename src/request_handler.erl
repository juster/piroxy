-module(request_handler).
-behavior(gen_event).

-import(lists, [flatmap/2, reverse/1, foreach/2]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([next_request/0]). % calls
-export([init/1, terminate/2, handle_event/2, handle_call/2, handle_info/2]).

%%% ETS records
-record(request, {key,target,head,inPid,n=0}).
-record(target, {key,outPid=null,reqs=[],n=0}).
-record(pid, {key,target,req=null}).

%%% called by the outbound process
next_request() ->
    gen_event:call(pievents, ?MODULE, {next_request,self()}).

%%% gen_event callbacks
%%%

init([]) ->
    {ok, ets:new(?MODULE, [set,private,{keypos,2}])}.

terminate(_Reason, Tab) ->
    killout(ets:first(Tab), Tab).

killout('$end_of_table', _) ->
    ok;
killout({pid,Pid}=K, Tab) ->
    exit(Pid, kill),
    killout(ets:next(Tab, K), Tab);
killout(K, Tab) ->
    killout(ets:next(Tab, K), Tab).

%%% First: handle internal responses that do not create outbound requests.

handle_event({make_request,Req,<<"*">>,#head{method=options}}, Tab) ->
    pievents:respond(Req, {status,ok}),
    pievents:close_response(Req),
    {ok,Tab};

handle_event({make_request,Req,Target,#head{method=connect}}, Tab) ->
    pievents:make_tunnel(Req, Target),
    {ok,Tab};

handle_event({make_request,Req,Target,Head}, Tab) ->
    %% TODO: check for WebSocket/HTTP2 requests here and upgrade them!
    %% convert data types first so we can fail before opening a socket
    ?LOG_DEBUG("make_request ~p:~n~p~n~s", [Req, Target, Head#head.line]),
    OutPid = connect_target(Tab, Target),
    {InPid,_} = Req,
    insert_request(Req, Tab, #request{target=Target,head=Head,inPid=InPid}),
    %% notify outbound there is a request waiting for them
    outbound:new_request(OutPid),
    {ok,Tab};

handle_event({stream_request,Req,Body}, S) ->
    morgue:append(Req, Body),
    {ok, S};

handle_event({end_request,Req}, S) ->
    morgue:append(Req, done),
    {ok, S};

%% cancel a request, remove it from the todo list.
handle_event({cancel_request,Req}, Tab) ->
    %% XXX: does not handle the case of a currently active Pid/request very well
    ?DBG("cancel_request", {request,Req}),
    case lookup_request(Tab,Req) of
        not_found ->
            ?LOG_WARNING("request (~p) not found when attempting to cancel", [Req]),
            {ok,Tab};
        R ->
            ets:delete(Tab, {request,Req}),
            Target = R#request.target,
            case lookup_target(Tab,Target) of
                not_found ->
                    ?DBG("cancel_request", {missing_target,Req,Target});
                #target{outPid=Pid,reqs=Reqs0} ->
                    Reqs = lists:delete(Req, Reqs0),
                    true = ets:update_element(Tab, {target,Target}, {#target.reqs,Reqs}),
                    case {Reqs, lookup_pid(Tab,Pid)} of
                        {_,not_found} ->
                            ?LOG_ERROR("pid (~p) not found when attempting to cancel request (~p)",
                                       [Pid, Req]);
                        {_,#pid{req=Req}} ->
                            %% The reference we are cancelling is currently active!!
                            %% The 'EXIT' handler will cleanup and handle reconnect
                            %% if necessary.
                            ?DBG("cancel_request", {closed,Pid}),
                            exit(Pid, closed);
                        {[],#pid{req=null}} ->
                            %% Request was cancelled before next_read() could be
                            %% called.
                            exit(Pid, closed);
                        {_,#pid{req=null}} ->
                            ?DBG("cancel_request", pid_null_request),
                            ?LOG_DEBUG("request is null for pid when cancelling ~p",
                                         [Req]),
                            ok;
                        {_,#pid{req=Req2}} ->
                            ?DBG("cancel_request", {pid_other_req,Req2}),
                            ?LOG_DEBUG("active request for pid (~p) is ~p and not ~p",
                                       [Pid, Req2, Req])
                    end
            end,
            {ok,Tab}
    end;

%% request is gracefully closed (i.e. finished)
handle_event({close_response,Req}, Tab) ->
    case lookup_request(Tab, Req) of
        not_found ->
            %% XXX: request was cancelled by inbound proc while still in process!!
            ?LOG_WARNING("request (~p) not found when attempting to close request", [Req]);
        #request{inPid=InPid, target=Target} ->
            case lookup_target(Tab, Target) of
                not_found ->
                    ?LOG_WARNING("target (~p) not found when attempting to close request.", [Req]);
                #target{outPid=OutPid} ->
                    ?DBG("end_request", {pid,OutPid,req,Req}),
                    true = ets:update_element(Tab, {pid,OutPid}, {#pid.req,closed}),
                    true = ets:delete(Tab, {request,Req})
            end
    end,
    {ok,Tab};

handle_event(_, State) ->
    {ok, State}.

handle_call({next_request,OutPid}, Tab) ->
    {ok, pop_request(Tab, OutPid), Tab}.

%% track outbound processes so that we can recreate them if they exit
handle_info({'EXIT',Pid,Reason}, Tab) ->
    %%?DBG("handle_info", {'EXIT',Pid,Reason}),
    try
        case lookup_pid(Tab, Pid) of
            not_found ->
                %%?DBG("handle_info", not_found),
                ok;
            #pid{target=Target, req=Req} ->
                cleanup_proc(Req, Pid, Target, Reason, Tab)
        end
    catch
        {error,Rsn} ->
            ?LOG_ERROR("error during cleanup of ~p: ~p", [{Pid,Reason}, Rsn])
    end,
    {ok, Tab}.

cleanup_proc(Req0, Pid, Target, Reason, Tab) ->
    TargetR = case lookup_target(Tab, Target) of
                  not_found ->
                      throw({error,{unknown_target,Target}});
                  R2 ->
                      R2
              end,
    {Req,ReqR} = case Req0 of
                     null -> {null,null};
                     closed -> {closed,null};
                     _ ->
                         %% XXX: if Req was cancelled it will now be not_found!
                         case lookup_request(Tab, Req0) of
                             not_found -> {null,null}; % override Req to be null
                             R -> {Req0,R}
                         end
                 end,
    ets:delete(Tab, {pid,Pid}), % process is gone
    %% target_error and request_error provide another level of indirection.
    %% These functions may override the task to be 'redo' and in the process
    %% control the number of redo attempts that should be made.
    Task = case fail_task(Reason, Req, TargetR#target.reqs) of
               {target_error,Reason2} ->
                   target_error(Tab, TargetR, Reason2);
               {request_error,Reason2} ->
                   request_error(Tab, ReqR, Reason2);
               T2 -> T2
           end,
    %%?DBG("handle_info", {{'EXIT',Pid,Reason1},{task,Task}}),
    perform_fail_task(Task, TargetR, ReqR, Tab),
    ok.

%%%
%%% internal utility functions
%%%

%% Requirements:
%%  1. Store new requests {inbound Pid, Head, Req} so they can be queued and
%%     sent to outbound Pids.
%%  2. Crossref hosts to outbound Pids when deciding whether to spawn a
%%     new outbound Pid or whether to reuse an existing one.
%%  3. Crossref outbound Pids to active requests so that I know which requests
%%     failed, when an outbound Pid exits on error.

%% Record types:
%% 1. {{request,Req}, Target, Head, InPid, Nfail}
%% 2. {{target,Target}, Pid, Reqs, Nfail}
%% 3. {{pid,Pid}, Target, Req}

lookup(Tab, Key) ->
    case ets:lookup(Tab, Key) of
        [] -> not_found;
        [R] -> R
    end.

lookup_request(Tab, Req) -> lookup(Tab, {request,Req}).
lookup_pid(Tab, Pid) -> lookup(Tab, {pid,Pid}).
lookup_target(Tab, Target) -> lookup(Tab, {target,Target}).

%% When a request is added, append it to the Target's request queue.
insert_request(Req, Tab, Request) ->
    ets:insert(Tab, Request#request{key={request,Req}}),
    Target = Request#request.target,
    #target{reqs=Reqs} = lookup_target(Tab, Target),
    true = ets:update_element(Tab, {target,Target}, {#target.reqs,[Req|Reqs]}).

%% Pop a new request from the request queue and associate it with an
%% outbound Pid.
pop_request(Tab, Pid) ->
    #pid{target=Target} = lookup_pid(Tab, Pid),
    case lookup_target(Tab, Target) of
        #target{reqs=[]} -> null;
        #target{reqs=Reqs0} ->
            [Req|Reqs] = reverse(Reqs0),
            true = ets:update_element(Tab, {target,Target},
                                      {#target.reqs,reverse(Reqs)}),
            true = ets:update_element(Tab, {pid,Pid}, {#pid.req,Req}),
            ?DBG("pop_request", {pid,Pid,target,Target,req,Req}),
            #request{head=Head} = lookup_request(Tab, Req),
            {ok, {Req,Head}}
    end.

connect_target(Tab, Target) ->
    case lookup_target(Tab, Target) of
        #target{outPid=Pid} ->
            Pid;
        not_found ->
            Pid = apply(outbound, connect, tuple_to_list(Target)),
            %% initialize empty request queue
            ets:insert(Tab, #target{key={target,Target}, outPid=Pid}),
            %% outbound request is null, starts off idle
            ets:insert(Tab, #pid{key={pid,Pid}, target=Target}),
            Pid
    end.

%% the request should be 'closed' after outbound calls end_request(Req).

%% No active requests so no big deal, ignore any error.
fail_task(_Reason,closed,[]) ->
    cleanup;

%% Happens when a request is cancelled before it gets a chance to be fetched by
%% outbound using request_handler:next_request().
fail_task(closed,null,[]) ->
    {trace, null_request_closed, cleanup};

%% Closed before any request could be queued, not good.
fail_task(closed,null,_Pending) ->
    {target_error,reset};

%% Pending requests but remote end gracefully closed socket.
fail_task(closed,closed,_Pending) ->
    retry;

%% Error before any request could be queued, not good.
fail_task(Reason,null,_Pending) ->
    {target_error,Reason};

%% Socket was closed on remote end yet we have more requests to make.
fail_task(Reason,closed,_Pending) ->
    {target_error,Reason};

%% Error or close in the middle of a request/response.
fail_task(Reason,_Req,_Pending) ->
    {request_error,Reason}.

request_error(Tab, #request{key=Key, n=Nfail}, Reason) ->
    N = Nfail+1,
    ?DBG("request_error", {n,N}),
    if
        N >= ?REQUEST_FAIL_MAX ->
            {failone,Reason};
        true ->
            ets:update_element(Tab, Key, {#request.n,N}),
            retry
    end.

target_error(Tab, #target{key=Key, n=Nfail}, Reason) ->
    N = Nfail+1,
    ?DBG("target_error", {Key,{n,N}}),
    if
        N >= ?TARGET_FAIL_MAX ->
            %%ets:delete(Tab, {target,Target}),
            {failall,Reason};
        true ->
            ets:update_element(Tab, Key, [{#target.n,N}]),
            retry
    end.

perform_fail_task({trace,T,Next}, TargetR, ReqR, Tab) ->
    ?LOG_DEBUG("target/req failure: ~s~n~p ~p",
               [T,TargetR#target.key,
                case ReqR of
                    null -> {request,null};
                    _ -> [ReqR#request.key]
                end]),
    perform_fail_task(Next, TargetR, ReqR, Tab);

perform_fail_task(cleanup, TargetR, ReqR, Tab) ->
    %% sanity check
    if
        is_tuple(ReqR) ->
            ?DBG("handle_info", "cleanup should have no active request!");
        true ->
            ok
    end,
    ets:delete(Tab, TargetR#target.key);

perform_fail_task({failone,Reason}, TargetR, ReqR, Tab) ->
    #request{key={request,Req}, inPid=Pid} = ReqR,
    pievents:fail_request(Req, Reason),
    ets:delete(Tab, ReqR#request.key),
    ?LOG_ERROR("Outbound request failed: ~p",
               [{request,element(2,ReqR#request.key),
                 target,element(2, TargetR#target.key),
                 reason,Reason}]);

perform_fail_task({failall,Reason}, TargetR, ReqR, Tab) ->
    Reqs = reverse(TargetR#target.reqs),
    Pids = [lookup_request(Tab, Ref) || Ref <- Reqs],
    %% The request of the failed proc is not in the queue for the task...
    %% But there may actually be no active request, either.
    L = case ReqR of
            #request{key={request,Ref}} ->
                [{Ref,ReqR}|lists:zip(Reqs, Pids)];
            null ->
                lists:zip(Reqs, Pids)
        end,
    foreach(fun ({Req, #request{inPid=Pid}}) ->
                    pievents:fail_request(Req, Reason),
                    ets:delete(Tab, {request,Req})
            end, L),
    ets:delete(Tab, TargetR#target.key),
    ?LOG_ERROR("Target requests failed: ~p",
               [{target,element(2, TargetR#target.key),reason,Reason}]);

perform_fail_task(retry, #target{key={target,Target}}, _ReqRec, Tab) ->
    ok = reconnect_target(Tab, Target);

perform_fail_task(retry, TargetR, ReqRec, Tab) ->
    #target{key={target,Target}, reqs=Pending} = TargetR,
    #request{key={request,Ref}} = ReqRec,
    ok = reconnect_target(Tab, Target, Pending++[Ref]).

reconnect_target(Tab, Target) ->
    Pid = apply(outbound, connect, tuple_to_list(Target)),
    %% do not modify the request queue of the target
    true = ets:update_element(Tab, {target,Target}, {#target.outPid,Pid}),
    ets:insert(Tab, #pid{key={pid,Pid}, target=Target}),
    ok.

reconnect_target(Tab, Target, Reqs) ->
    ok = reconnect_target(Tab, Target),
    true = ets:update_element(Tab, {target,Target}, {#target.reqs,Reqs}),
    ok.
