-module(request_target).
-behavior(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").
-import(lists, [foreach/2, unzip/1, unzip3/1,
                keytake/3, keymember/3, keydelete/3]).

-export([start_link/1, make_request/3, cancel_request/2, need_request/1,
         close_request/2]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2,
         handle_info/2]).

%%% called by request_handler

start_link(HostInfo) ->
    gen_server:start_link(?MODULE, [HostInfo], []).

make_request(Pid, Req, Head) ->
    gen_server:cast(Pid, {make_request,Req,Head}).

cancel_request(Pid, Req) ->
    gen_server:cast(Pid, {cancel_request,Req}).

close_request(Pid, Req) ->
    gen_server:cast(Pid, {close_request,Req}).

%%% called by outbound

need_request(Pid) ->
    gen_server:cast(Pid, {need_request,self()}).

init([HostInfo]) ->
    process_flag(trap_exit, true),
    {ok,_Pid} = outbound:start_link(HostInfo),
    %% State: {[{Req,Head}], [{Req,Head,Pid}], [WaitingPids],
    %%         {Nprocs,MaxProcs,Nfails}, HostInfo}
    {ok, {[],[],[],{1,1,0},HostInfo}}.

terminate(Reason, {Ltodo,Lsent,_,_,_}) ->
    %% XXX: Child procs should be exited automatically after teminate.
    Reqs = element(1,unzip(Ltodo)) ++ element(1,unzip3(Lsent)),
    foreach(fun (Req) -> pievents:fail_request(Req, Reason) end, Reqs),
    ok.

handle_call(_, _, State) ->
    {reply, ok, State}.

%%%
%%% from request_handler
%%%

handle_cast({make_request,Req,Head}, State0) ->
    Lsent0 = element(2,State0),
    case element(3,State0) of
        [Pid|Waitlist] ->
            %% we have a proc waiting for a request...
            outbound:next_request(Pid, Req, Head),
            Lsent = Lsent0 ++ [{Req,Head,Pid}],
            State1 = setelement(2,State0,Lsent),
            State2 = setelement(3,State1,Waitlist),
            {noreply,State2};
        [] ->
            %% either create a new proc or add to the todo list
            {Nproc,Nmax,Nfail} = element(4,State0),
            Ltodo = element(1,State0) ++ [{Req,Head}],
            State1 = setelement(1,State0,Ltodo),
            if
                Nproc >= Nmax ->
                    %% already at max allowed procs, add to todo list
                    {noreply,State1};
                true ->
                    %% spawn a new proc
                    {ok,Pid} = outbound:start_link(element(5,State0)),
                    Lsent = Lsent0 ++ [{Req,Head,Pid}],
                    State2 = setelement(2,State1,Lsent),
                    State3 = setelement(4,State2,{Nproc+1,Nmax,Nfail}),
                    {noreply,State3}
            end
    end;

%%%
%%% from outbound
%%%

handle_cast({need_request,Pid}, State0) ->
    case element(1,State0) of
        [] ->
            %% If todo list is empty, then add Pid to waiting list.
            Waitlist = element(3,State0) ++ [Pid],
            State1 = setelement(3,State0,Waitlist),
            {noreply, State1};
        [{Req,Head}|Ltodo] ->
            %% O/W pop off the todo list and push to sent list.
            Lsent = element(2,State0) ++ [{Req,Head,Pid}],
            State1 = setelement(1,State0,Ltodo),
            State2 = setelement(2,State1,Lsent),
            outbound:next_request(Pid, Req, Head),
            morgue:forward(Req, Pid),
            {noreply, State2}
    end;

%%% Called when the request is finished (i.e. the response is completed).
handle_cast({close_request,Req}, State0) ->
    Lsent0 = element(2,State0),
    Lsent = keydelete(Req, 1, Lsent0),
    State1 = setelement(2,State0,Lsent),
    morgue:forget(Req),
    %% Increase the number of max possible workers until we reach hard limit.
    {Nproc,Nmax,Nfail} = element(4,State1),
    if
        Nproc >= Nmax ->
            %% We already hit the ceiling.
            {noreply,State1};
        true ->
            {ok,_} = outbound:start_link(element(5,State1)),
            State2 = setelement(4,State1,{Nproc+1,Nmax,Nfail}),
            {noreply,State2}
    end;

%%% Called when outbound cannot make a request work.
handle_cast({fail_request,Req,Reason}, State0) ->
    Lsent0 = element(2,State0),
    case keytake(Req, 1, Lsent0) of
        false ->
            ?LOG_ERROR("fail_request: unknown request (~p)", [Req]),
            {noreply,State0};
        {value,{Req,_,_},Lsent1} ->
            pievents:fail_request(Req, Reason),
            State1 = setelement(2,State0,Lsent1),
            {noreply,State1}
    end;

handle_cast(_, State) ->
    {noreply,State}.

%% Unexpected errors in outbound process causes a target error.
handle_info({'EXIT',Pid,Reason}, State0) ->
    Lwait = lists:delete(Pid, element(3,State0)),
    {Nproc,Nmax,Nfail0} = element(4,State0),
    State1 = redo(Pid, State0),
    State2 = setelement(3,State1,Lwait),
    Nfail = if
                %% Normal errors do not cause a target error.
                Reason =:= normal; Reason =:= timeout ->
                    Nfail0;
                true ->
                    Nfail0+1
            end,
    if
        Nfail >= ?TARGET_FAIL_MAX ->
            %% terminate will notify the requests of failure
            {stop,Reason,State2};
        Nproc =< Nmax, element(1,State2) =/= [] ->
            %% reconnect new target proc if we haven't (somehow) gone over limit
            %% AND we actually have more pending requests
            outbound:start_link(element(5,State2)),
            State3 = setelement(4,State2,{Nproc,Nmax,Nfail}),
            {noreply,State3};
        true ->
            State3 = setelement(4,State2,{Nproc-1,Nmax,Nfail}),
            {noreply,State3}
    end;

handle_info(_, State) ->
    {noreply,State}.

keywipe(K, I, L0) ->
    keywipe(K, I, L0, []).

keywipe(K, I, L0, Ts) ->
    case keytake(K, I, L0) of
        false ->
            {Ts, L0};
        {value, T, L} ->
            keywipe(K, I, L, [T|Ts])
    end.

redo(Pid, State0) ->
    {L,Lsent} = keywipe(Pid, 3, element(2,State0)),
    foreach(fun ({Req,_,_}) -> morgue:mute(Req) end, L),
    Ltodo = [{Req,Head} || {Req,Head,_} <- L] ++ element(1,State0),
    State1 = setelement(1, State0, Ltodo),
    setelement(2, State1, Lsent).
