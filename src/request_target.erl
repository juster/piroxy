-module(request_target).
-behavior(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("../include/pihttp_lib.hrl").
-import(lists, [foreach/2, reverse/1, keytake/3, keydelete/3, partition/2,
                filter/2, any/2]).

-define(MAX_SOCKETS, 4).
-record(stats, {nfail=0,nsuccess=0}).
-record(state, {sent=[], pids=erlang:make_tuple(?MAX_SOCKETS, null),
                i=0, stats=#stats{}, hostinfo}).

%% Awful.
%%-define(DEC(Field, S), S#state{stats=S#state.stats#stats{Field=(S#state.stats)#stats.Field-1}}).
-define(INC(Field, S), S#state{stats=S#state.stats#stats{Field=(S#state.stats)#stats.Field+1}}).

-export([start_link/1, connect/2, cancel/2, finish/2, pending/1]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).

%%% called by request_manager

start_link(HostInfo) ->
    gen_server:start_link(?MODULE, [HostInfo], []).

connect(Pid, Id) ->
    gen_server:cast(Pid, {connect,Id}).

cancel(Pid, Id) ->
    gen_server:cast(Pid, {cancel,Id}).

%%% called by http_res_sock

finish(Pid, Res) ->
    gen_server:cast(Pid, {finish,Res}).

%%% used during debugging

pending(Pid) ->
    gen_server:call(Pid, pending).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([HostInfo]) ->
    process_flag(trap_exit, true),
    {ok, #state{hostinfo=HostInfo}}.

terminate(Reason, #state{sent=Lsent}) ->
    %% XXX: Child procs should be exited automatically after teminate.
    %%?DBG("terminate", ding),
    foreach(fun ({_Pid,Req}) ->
                    fail(Req, Reason)
            end, Lsent),
    ok.

handle_call(pending, _From, S) ->
    {reply, [Req || {_,Req} <- S#state.sent], S}.

%%%
%%% from request_manager
%%%

handle_cast({connect,Req}, S0) ->
    {Pid,I,S} = next_sock_proc(S0),
    case http_pipe:listen(Req, Pid) of
        ok ->
            %% Advance the counter, so that we use the next slot for the next
            %% request.
            Lsent = S#state.sent ++ [{Pid,Req}],
            {noreply, S#state{i=I, sent=Lsent}};
        {error,unknown_session} ->
            %% Does not advance the counter so that the next time connect is
            %% called, we reuse the last process.
            io:format("*DBG* [request_target] (~s) unknown_session~n",
                      [element(2,S#state.hostinfo)]),
            {noreply, S};
        {error,Rsn} ->
            %% There should be no other error reasons.
            error(Rsn)
    end;

handle_cast({cancel,Id}, S0) ->
    Lsent = lists:keydelete(Id, 2, S0#state.sent),
    {noreply, S0#state{sent=Lsent}};

%%%
%%% from http_res_sock
%%%

%%% Called when the request is finished (i.e. the response is completed).
handle_cast({finish,Res}, S0) ->
    Lsent = keydelete(Res, 2, S0#state.sent),
    %%?DBG("finish", [{res,Res}]),
    {noreply, ?INC(nsuccess, S0#state{sent=Lsent})};

%%% retire_self is called when an outbound pid upgrades their protocol.
handle_cast({retire_self,Pid}, S) ->
    unlink(Pid),
    {L,Lsent} = partpid(Pid, S#state.sent),
    {noreply, resend(Pid, L, S#state{sent=Lsent})}.

%% Unexpected errors in outbound process.
handle_info({'EXIT',Pid,Reason}, S0) ->
    ?TRACE(0, element(2,S0#state.hostinfo), ">>",
           io_lib:format("outbound closed: ~p", [Reason])),
    FailType = failure_type(Reason),
    S1 = case FailType of
             soft ->
                 %%L1 = S0#state.todo,
                 %%S_ = redo(Pid, S0),
                 %%L2 = lists:subtract(L1, S_#state.todo),
                 %%?DBG("handle_info", [{redoing, L2}]),
                 %%S_;
                 S0;
             hard ->
                 ?INC(nfail, S0);
             fatal ->
                 ?INC(nfail, S0)
         end,
    {L0,Lsent} = partpid(Pid, S1#state.sent),
    if
        S1#state.stats#stats.nfail > 5 ->
            %% We have reached the maximum failure count, so we must abort.
            {stop,Reason,S1};
        true ->
            if
                FailType == fatal ->
                    %% Fail the first request that was sent to Pid.
                    %% Redo the rest of the requests.
                    ?DBG("EXIT", [{failtype,fatal}]),
                    case L0 of
                        [] ->
                            %% We should have at least a single sent request.
                            error(Reason);
                        [{_,Req1}|L1] ->
                            fail(Req1, Reason),
                            S2 = resend(Pid, [Req || {_,Req} <- L1], S1#state{sent=Lsent}),
                            {noreply, S2}
                    end;
                FailType == soft; FailType == hard ->
                    S2 = resend(Pid, [Req || {_,Req} <- L0], S1#state{sent=Lsent}),
                    {noreply, S2}
            end
    end.

%% Use a circular buffer for assigning requests to each proc in round-robin
%% fashion.
next_sock_proc(S) ->
    I = S#state.i+1, % I is 1-indexed [1..maxpid]
    J = I rem ?MAX_SOCKETS, % J is 0-indexed [0..maxpid-1]
    case element(I, S#state.pids) of
        null ->
            %% Empty slot, spawn a new proc.
            case http_res_sock:start_link(S#state.hostinfo) of
                {ok,Pid} ->
                    Pids = setelement(I, S#state.pids, Pid),
                    {Pid,J,S#state{pids=Pids}};
                {error,Rsn} ->
                    error(Rsn)
            end;
        Pid ->
            %% Reuse an existing slot.
            {Pid,J,S}
    end.

failure_type(normal) -> soft;
failure_type(shutdown) -> soft;
failure_type({shutdown,reset}) -> soft;
failure_type({shutdown,timeout}) -> hard;
failure_type({ssl_error,_}) -> hard;
failure_type({tcp_error,_}) -> hard;
failure_type(_) -> fatal.

fail(Id, Reason) ->
    http_pipe:rewind(Id),
    http_pipe:recv(Id, {error,Reason}),
    http_pipe:recv(Id, eof).

tfind(X, T) ->
    tfind(X, T, 1).

tfind(_, T, I) when I > tuple_size(T) ->
    error(not_found);

tfind(X, T, I) when element(I,T) =:= X ->
    I;

tfind(X, T, I) ->
    tfind(X, T, I+1).

partpid(Pid, Lsent) ->
    partition(fun ({Pid_,_})
                    when Pid == Pid_ ->
                      true;
                  (_) ->
                      false
              end, Lsent).

resend(Pid, L, S0) ->
    S = resend2(Pid, L, S0),
    case active(S) of
        true ->
            S;
        false ->
            throw({stop,shutdown,S0})
    end.

resend2(Pid, [], S) ->
    %% Special case: there is nothing to resend.
    I = tfind(Pid, S#state.pids),
    Tpids = setelement(I, S#state.pids, null),
    S#state{pids=Tpids};

resend2(Pid0, L0, S) ->
    %% Things get a little juicy when we account for pipe endpoints which have
    %% since ceased to exist.
    case http_res_sock:start_link(S#state.hostinfo) of
        {ok,Pid} ->
            foreach(fun (Req) -> http_pipe:rewind(Req) end, L0),
            L = relay(Pid, L0), % L may be empty!
            I = tfind(Pid0, S#state.pids),
            Tpids = setelement(I, S#state.pids, Pid),
            Lsent = S#state.sent ++ [{Pid,Req} || Req <- L],
            S#state{pids=Tpids, sent=Lsent};
        {error,Rsn} ->
            error(Rsn)
    end.

relay(Pid, Reqs) ->
    filter(fun (Req) ->
                   case http_pipe:listen(Req, Pid) of
                       ok ->
                           true;
                       {error,unknown_session} ->
                           false;
                       {error,Reason} ->
                           error(Reason)
                   end
           end, Reqs).

active(S) ->
    any(fun (null) -> false; (_) -> true end,
        tuple_to_list(S#state.pids)).
