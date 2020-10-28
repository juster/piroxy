-module(request_target).
-behavior(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").
-import(lists, [foreach/2, unzip/1, unzip3/1, reverse/1,
                keytake/3, keymember/3, keydelete/3]).
-record(state, {todo=[], sent=[], waitlist=[], stats, hostinfo}).

-export([start_link/1, make_request/3, cancel_request/2, need_request/1,
         request_done/2, pending_requests/1]).
-export([init/1, terminate/2,
         handle_call/3, handle_cast/2, handle_continue/2, handle_info/2]).

%%% called by request_handler

start_link(HostInfo) ->
    gen_server:start_link(?MODULE, [HostInfo], []).

make_request(Pid, Req, Head) ->
    gen_server:cast(Pid, {make_request,Req,Head}).

cancel_request(Pid, Req) ->
    gen_server:cast(Pid, {cancel_request,Req}).

request_done(Pid, Req) ->
    gen_server:cast(Pid, {request_done,Req}).

%%% called by outbound

need_request(Pid) ->
    gen_server:cast(Pid, {need_request,self()}).

%%% called by whomever

pending_requests(Pid) ->
    gen_server:call(Pid, pending_requests).

init([HostInfo]) ->
    process_flag(trap_exit, true),
    {ok,_Pid} = outbound:start_link(HostInfo),
    {ok, #state{stats={1,1,0,0}, hostinfo=HostInfo}}.

terminate(Reason, #state{todo=Ltodo, sent=Lsent}) ->
    %% XXX: Child procs should be exited automatically after teminate.
    foreach(fun ({Req,_}) -> pievents:fail_request(Req, Reason) end, Ltodo),
    foreach(fun ({Req,_,_}) -> pievents:fail_request(Req, Reason) end, Lsent),
    ok.

handle_call(pending_requests, _From, S) ->
    {reply, [Req || {Req,_,_} <- S#state.sent], S};

handle_call(_, _, S) ->
    {reply, ok, S}.

%%%
%%% from request_manager
%%%

handle_cast({make_request,Req,Head}, S0) ->
    case S0#state.waitlist of
        [Pid|Waitlist] ->
            %% we have a proc waiting for a request...
            S1 = send_request(Pid, Req, Head, S0),
            S2 = S1#state{waitlist=Waitlist},
            {noreply,S2};
        [] ->
            %% store the request in the todo list and perhaps spawn a new proc
            {Nproc,Nmax,Nfail,Nsuccess} = S0#state.stats,
            Ltodo = S0#state.todo ++ [{Req,Head}],
            S1 = S0#state{todo=Ltodo},
            if
                Nproc >= Nmax ->
                    %% already at max allowed procs, add to todo list
                    {noreply,S1};
                true ->
                    %% spawn a new proc
                    {ok,_Pid} = outbound:start_link(S1#state.hostinfo),
                    S2 = S1#state{stats={Nproc+1,Nmax,Nfail,Nsuccess}},
                    {noreply,S2}
            end
    end;

handle_cast({cancel_request,Req}, S) ->
    %% this will also execute if no such Req exists in either list
    Ltodo = lists:keydelete(Req, 1, S#state.todo),
    case lists:keyfind(Req, 1, S#state.sent) of
        false ->
            {noreply, S#state{todo=Ltodo}};
        {Req,_,Pid} ->
            %% we were unlucky and the request is in progress
            %% cancel it to force a restart
            exit(Pid, cancelled),
            Lsent = lists:keydelete(Req, 1, S#state.sent),
            {noreply, S#state{todo=Ltodo, sent=Lsent}}
    end;

%%%
%%% from outbound
%%%

handle_cast({need_request,Pid}, S0) ->
    case S0#state.todo of
        [] ->
            %% If todo list is empty, then add Pid to waiting list.
            Waitlist = S0#state.waitlist ++ [Pid],
            S1 = S0#state{waitlist=Waitlist},
            {noreply, S1};
        [{Req,Head}|Ltodo] ->
            %% O/W pop off the todo list and push to sent list.
            S1 = S0#state{todo=Ltodo},
            S2 = send_request(Pid, Req, Head, S1),
            {noreply, S2}
    end;

%%% Called when the request is finished (i.e. the response is completed).
handle_cast({request_done,Req}, S0) ->
    %%?DBG("request_done", [{req,Req}]),
    Lsent0 = S0#state.sent,
    Lsent = keydelete(Req, 1, Lsent0),
    S1 = S0#state{sent=Lsent},
    morgue:forget(Req),
    %% Increase the number of max possible workers until we reach hard limit.
    {Nproc,Nmax,Nfail,Nsuccess} = S1#state.stats,
    S2 = S1#state{stats={Nproc,Nmax,Nfail,Nsuccess+1}},
    if
        Nproc >= Nmax ->
            %% We already hit the ceiling.
            {noreply,S2};
        true ->
            {ok,_} = outbound:start_link(S1#state.hostinfo),
            S3 = S2#state{stats={Nproc+1,Nmax,Nfail,Nsuccess}},
            {noreply,S3}
    end;

%%% Called when outbound cannot make a request work.
handle_cast({fail_request,Req,Reason}, S0) ->
    Lsent0 = S0#state.sent,
    case keytake(Req, 1, Lsent0) of
        false ->
            ?LOG_ERROR("fail_request: unknown request (~p)", [Req]),
            {noreply,S0};
        {value,{Req,_,_},Lsent1} ->
            pievents:fail_request(Req, Reason),
            S1 = S0#state{sent=Lsent1},
            {noreply,S1}
    end;

handle_cast(_, S) ->
    {noreply,S}.

handle_continue(check_waitlist, S0) ->
    case {S0#state.sent, S0#state.waitlist} of
        {[],_} ->
            {noreply,S0};
        {_,[]} ->
            {noreply,S0};
        {[{Req,Head}|Ltodo], [Pid|Waitlist]} ->
            S1 = send_request(Pid, Req, Head, S0),
            S2 = S1#state{todo=Ltodo},
            S3 = S2#state{waitlist=Waitlist},
            {noreply,S3}
    end.

%% Unexpected errors in outbound process causes a target error.
handle_info({'EXIT',Pid,Reason}, S0) ->
    Lwait = lists:delete(Pid, S0#state.waitlist),
    {Nproc,Nmax,Nfail0,Nsuccess} = S0#state.stats,
    S1 = S0#state{waitlist=Lwait},
    S2 = redo(Pid, S1),
    Failure = is_failure(Reason, S2),
    %% Normal errors do not cause a target error.
    Nfail = if
                Failure ->
                    Nfail0+1;
                true ->
                    Nfail0
            end,
    ?DBG("handle_info", [{reason,Reason},{failure,Failure}]),
    %%?DBG("handle_info", [{hostinfo,S0#state.hostinfo},{pid,Pid},
    %%                     {reason,Reason},{nproc,Nproc},{nmax,Nmax},
    %%                     {nfail,Nfail},{nrestarts,Nsuccess}]),
    if
        Failure, Nfail >= ?TARGET_FAIL_MAX ->
            %% terminate/2 will notify the requests of failure
            {stop,Reason,S0};
        S2#state.todo == [], S2#state.sent == [] ->
            %% cleanup if there are no more requests needed and/or active
            {stop,shutdown,S0};
        Nproc =< Nmax, S2#state.todo =/= [] ->
            %% reconnect new target proc if we haven't (somehow) gone
            %% over limit AND we actually have more pending requests
            {ok,OutPid} = outbound:start_link(S2#state.hostinfo),
            S3 = S2#state{stats={Nproc,Nmax,Nfail,Nsuccess}},
            ?DBG("handle_info", [{pid,OutPid},
                                 {todo,[{Req,H#head.line}
                                        || {Req,H} <- S3#state.todo]},
                                 {stats,{Nproc,Nmax,Nfail,Nsuccess}}]),
            {noreply,S3,{continue,check_waitlist}};
        true ->
            S3 = S2#state{stats={Nproc-1,Nmax,Nfail,Nsuccess}},
            {noreply,S3,{continue,check_waitlist}}
    end;

handle_info(_, S) ->
    {noreply,S}.

%% Being closed before any successful request/response is a fail.
is_failure({shutdown,closed}, #state{stats={_,_,_,0}}) -> true;
is_failure({shutdown,closed}, _) -> false;
is_failure(cancelled, _) -> false;
is_failure(_, _) -> true.

keywipe(K, I, L0) ->
    keywipe(K, I, L0, []).

keywipe(K, I, L0, Ts) ->
    case keytake(K, I, L0) of
        false ->
            {reverse(Ts), L0};
        {value, T, L} ->
            keywipe(K, I, L, [T|Ts])
    end.

%%% Move requests that were sent to Pid back into todo list
%%% NOTE: there MAY be 0 entries to move back to the todo list!
%%% (this happens when a request is cancelled while it is in progress)
redo(Pid, S) ->
    {L0,Lsent} = keywipe(Pid, 3, S#state.sent),
    L = [{Req,Head} || {Req,Head,_} <- L0],
    foreach(fun ({Req,_}) -> morgue:mute(Req) end, L),
    Ltodo = L ++ S#state.todo, % move to front of todo list
    S#state{todo=Ltodo, sent=Lsent}.

send_request(Pid, Req, Head, S) ->
    outbound:next_request(Pid, Req, Head),
    morgue:forward(Req, Pid),
    Lsent0 = S#state.sent,
    S#state{sent=Lsent0 ++ [{Req,Head,Pid}]}.
