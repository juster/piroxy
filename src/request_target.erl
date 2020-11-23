-module(request_target).
-behavior(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").
-import(lists, [foreach/2, reverse/1, keytake/3, keydelete/3, partition/2,
                filter/2, any/2]).

-define(MAX_SOCKETS, 4).
-record(stats, {nfail=0,nsuccess=0}).
-record(state, {sent=[], pids=erlang:make_tuple(?MAX_SOCKETS, null),
                i=0, stats=#stats{}, hostinfo}).

%% Awful.
%%-define(DEC(Field, S), S#state{stats=S#state.stats#stats{Field=(S#state.stats)#stats.Field-1}}).
-define(INC(Field, S), S#state{stats=S#state.stats#stats{Field=(S#state.stats)#stats.Field+1}}).

-export([start_link/1, connect/2, cancel/2, finish/2, pending/1, retire_self/1]).
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

retire_self(Pid) ->
    gen_server:cast(Pid, {retire_self,self()}).

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
    {reply, [Req || {_,Req} <- S#state.sent], S};

handle_call(_, _, S) ->
    {reply, ok, S}.

%%%
%%% from request_manager
%%%

handle_cast({connect,Req}, S) ->
    %% Use a circular buffer for assigning requests to each proc.
    I = S#state.i+1,
    J = I rem ?MAX_SOCKETS,
    case element(I, S#state.pids) of
        null ->
            %% Empty slot, spawn a new proc.
            case http_res_sock:start_link(S#state.hostinfo) of
                {ok,Pid} ->
                    case http_pipe:listen(Req, Pid) of
                        ok ->
                            Pids = setelement(I, S#state.pids, Pid),
                            Lsent = S#state.sent ++ [{Pid,Req}],
                            {noreply, S#state{i=J, pids=Pids, sent=Lsent}};
                        {error,unknown_session} ->
                            {noreply, S}
                    end;
                {error,Rsn} ->
                    exit(Rsn)
            end;
        Pid ->
            %% Reuse an existing slot.
            case http_pipe:listen(Req, Pid) of
                ok ->
                    Lsent = S#state.sent ++ [{Pid,Req}],
                    {noreply, S#state{i=J, sent=Lsent}};
                {error,unknown_session} ->
                    {noreply, S}
            end
    end;

handle_cast({cancel,Id}, S0) ->
    case keytake(Id, 2, S0#state.sent) of
        false ->
            %% Ignore requests we are not responsible for.
            {noreply, S0};
        {value,{Pid,_},Lsent} ->
            %% We must restart the process because the cancelled request has
            %% corrupted the pipeline. We cannot be sure where in the
            %% request/response pipeline the request currently is.
            ?DBG("cancel", [{session,Id},{stopping,Pid}]),
            http_res_sock:stop(Pid),
            {noreply, S0#state{sent=Lsent}}
    end;

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

failure_type(normal) -> soft;
failure_type(shutdown) -> soft;
failure_type({shutdown,timeout}) -> hard;
failure_type({ssl_error,_}) -> hard;
failure_type({tcp_error,_}) -> hard;
failure_type({shutdown,cancelled}) -> hard;
failure_type(_) -> fatal.

fail(Id, Reason) ->
    http_pipe:reset(Id),
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
            foreach(fun (Req) -> http_pipe:reset(Req) end, L0),
            L = relay(Pid, L0),
            I = tfind(Pid0, S#state.pids),
            Tpids = case L of
                        [] ->
                            http_res_sock:stop(Pid),
                            setelement(I, S#state.pids, null);
                        L ->
                            setelement(I, S#state.pids, Pid)
                    end,
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
