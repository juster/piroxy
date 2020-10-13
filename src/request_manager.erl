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

-record(request, {key,target,head,inPid,n=0}).
-record(target, {key,outPid=null,reqs=[],n=0}).
-record(pid, {key,target,req=null}).

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
            Tab = ets:new(?MODULE, [set,private,{keypos,2}]),
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
    Ref = insert_request(Tab, #request{target=Target,head=Head,inPid=InPid}),
    %% notify outbound there is a request waiting for them
    outbound:new_request(OutPid),
    {reply, Ref, Tab};

handle_call({next_request}, {OutPid,_}, Tab) ->
    {reply, pop_request(Tab, OutPid), Tab}.

%% request is gracefully closed (i.e. finished)
handle_cast({close_request,OutPid,Ref}, Tab) ->
    case lookup_request(Tab, Ref) of
        not_found ->
            %% XXX: request was cancelled by inbound proc while still in process!!
            ?DBG("close_request", {not_found,Ref}),
            {noreply,Tab};
        #request{inPid=InPid} ->
            ?DBG("close_request", {found,Ref}),
            true = ets:update_element(Tab, {pid,OutPid}, {#pid.req,closed}),
            ets:delete(Tab, {request,Ref}),
            inbound:close(InPid, Ref),
            {noreply,Tab}
    end;

%% cancel a request, remove it from the todo list.
handle_cast({cancel_request,Ref}, Tab) ->
    %% XXX: does not handle the case of a currently active Pid/request very well
    ?DBG("cancel_request", {request,Ref}),
    case lookup_request(Tab,Ref) of
        not_found ->
            ?DBG("cancel_request", not_found),
            {noreply,Tab};
        Req ->
            ets:delete(Tab, {request,Ref}),
            Target = Req#request.target,
            case lookup_target(Tab,Target) of
                not_found ->
                    ?DBG("cancel_request", {missing_target,Ref,Target});
                #target{outPid=Pid,reqs=Reqs0} ->
                    Reqs = lists:delete(Ref, Reqs0),
                    true = ets:update_element(Tab, {target,Target}, {#target.reqs,Reqs}),
                    case lookup_pid(Tab,Pid) of
                        not_found ->
                            ?DBG("cancel_request", {missing_pid,Pid}),
                            ok;
                        #pid{req=Ref} ->
                            %% The reference we are cancelling is currently active!!
                            %% The 'EXIT' handler will cleanup and handle reconnect
                            %% if necessary.
                            ?DBG("cancel_request", {closed,Pid}),
                            exit(Pid, closed);
                        #pid{req=null} ->
                            ?DBG("cancel_request", pid_null_request),
                            ok;
                        #pid{req=Ref2} ->
                            ?DBG("cancel_request", {pid_other_req,Ref2}),
                            ok
                    end
            end,
            {noreply,Tab}
    end.

%% track outbound processes so that was can recreate them if they exit
handle_info({'EXIT',OldPid,Reason1}, Tab) ->
    ?DBG("handle_info", {'EXIT',OldPid,Reason1}),
    #pid{target=Target, req=Ref} = lookup_pid(Tab, OldPid),
    TargetR = lookup_target(Tab, Target),
    {Req,ReqR} = case Ref of
                     null -> {null,null};
                     closed -> {closed,null};
                     Ref when is_reference(Ref) ->
                         %% XXX: if Req was cancelled it will now be not_found!
                         case lookup_request(Tab, Ref) of
                             not_found -> {null,null}; % override Ref to be null
                             R -> {Ref,R}
                         end;
                     _ ->
                         io:format("~p~n", [ets:tab2list(Tab)]),
                         error({corrupt_pid_record,{OldPid,Target,Ref}})
             end,
    ets:delete(Tab, {pid,OldPid}), % process is gone
    %% target_error and request_error provide another level of indirection.
    %% These functions may override the task to be 'redo' and in the process
    %% control the number of redo attempts that should be made.
    Task = case fail_task(Reason1, Req, TargetR#target.reqs) of
               {target_error,Reason2} ->
                   target_error(Tab, TargetR, Reason2);
               {request_error,Reason2} ->
                   request_error(Tab, ReqR, Reason2);
               T2 -> T2
           end,
    %%?DBG("handle_info", {{'EXIT',OldPid,Reason1},{task,Task}}),
    perform_fail_task(Task, TargetR, ReqR, Tab),
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
        [R] -> R
    end.

lookup_request(Tab, Ref) -> lookup(Tab, {request,Ref}).
lookup_pid(Tab, Pid) -> lookup(Tab, {pid,Pid}).
lookup_target(Tab, Target) -> lookup(Tab, {target,Target}).

%% When a request is added, append it to the Target's request queue.
insert_request(Tab, Request) ->
    Ref = make_ref(),
    ets:insert(Tab, Request#request{key={request,Ref}}),
    Target = Request#request.target,
    #target{reqs=Reqs} = lookup_target(Tab, Target),
    true = ets:update_element(Tab, {target,Target}, {#target.reqs,[Ref|Reqs]}),
    Ref.

%% Pop a new request from the request queue and associate it with an
%% outbound Pid.
pop_request(Tab, Pid) ->
    #pid{target=Target} = lookup_pid(Tab, Pid),
    case lookup_target(Tab, Target) of
        #target{reqs=[]} -> null;
        #target{reqs=Reqs0} ->
            [Req|Reqs] = reverse(Reqs0),
            true = ets:update_element(Tab, {target,Target}, {#target.reqs,reverse(Reqs)}),
            true = ets:update_element(Tab, {pid,Pid}, {#pid.req,Req}),
            #request{inPid=InPid,head=Head} = lookup_request(Tab, Req),
            {InPid,Req,Head}
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

%% Error before any request could be queued, not good.
fail_task(Reason,null,_Pending) ->
    {target_error,Reason};

%% Pending requests but some error occurred.
fail_task(Reason,closed,_Pending) ->
    {target_error,Reason};

%% Error or close in the middle of a request/response.
fail_task(Reason,Req,_Pending) when is_reference(Req) ->
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

perform_fail_task(cleanup, TargetR, ReqR, Tab) ->
    %% sanity check
    if
        is_tuple(ReqR) ->
            ?DBG("handle_info", "cleanup should have no active request!");
        true ->
            ok
    end,
    ets:delete(Tab, TargetR#target.key);

perform_fail_task({failone,Reason}, _TargetR, ReqR, Tab) ->
    #request{key={request,Ref}, inPid=Pid} = ReqR,
    inbound:fail(Pid, Ref, Reason),
    ets:delete(Tab, ReqR#request.key);

perform_fail_task({failall,Reason}, TargetR, ReqR, Tab) ->
    Refs = reverse(TargetR#target.reqs),
    Pids = [lookup_request(Tab, Ref) || Ref <- Refs],
    %% The request of the failed proc is not in the queue for the task...
    %% But there may actually be no active request, either.
    L = case ReqR of
            #request{key={request,Ref}} ->
                [{Ref,ReqR}|lists:zip(Refs, Pids)];
            null ->
                lists:zip(Refs, Pids)
        end,
    foreach(fun ({Ref, #request{inPid=Pid}}) ->
                    inbound:fail(Pid, Ref, Reason),
                    ets:delete(Tab, {request,Ref})
            end, L),
    ets:delete(Tab, TargetR#target.key);

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
