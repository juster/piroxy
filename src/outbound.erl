-module(outbound).

-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-import(erlang, [system_time/0, convert_time_unit/3]).
-import(lists, [foreach/2]).

-export([start_link/1, start/4, next_request/3]).

%%%
%%% EXTERNAL FUNCTIONS
%%%

start_link({http, Host, Port}) ->
    {ok,spawn_link(?MODULE, start, [self(), binary_to_list(Host), Port, false])};

start_link({https, Host, Port}) ->
    {ok,spawn_link(?MODULE, start, [self(), binary_to_list(Host), Port, true])}.

%% notify the outbound Pid that a new request is ready for it to send/recv
next_request(Pid, Req, Head) ->
    Pid ! {next_request,Req,Head},
    ok.

%%%
%%% INTERNAL FUNCTIONS
%%%

start(Pid, Host, Port, false) ->
    case gen_tcp:connect(Host, Port, [{active,true},binary,{packet,0},
                                      {exit_on_close,false}],
                         ?CONNECT_TIMEOUT) of
        {error, Reason} ->
            exit(Reason);
        {ok, Sock} ->
            start2(Pid, {tcp,Sock})
    end;

start(Pid, Host, Port, true) ->
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0},
                                  {exit_on_close,false}],
                     ?CONNECT_TIMEOUT) of
        {error,Reason} ->
            exit(Reason);
        {ok,Sock} ->
            ssl:setopts(Sock, [{active,true}]),
            start2(Pid, {ssl,Sock})
    end.

start2(TargetPid, Sock) ->
    {ok,StatePid} = http11_res:start_link(TargetPid),
    request_target:need_request(TargetPid),
    loop(TargetPid, Sock, pipipe:new(), null, StatePid),
    http11_res:stop(StatePid).

loop(Pid, Sock, P0, Clock, Stm) ->
    receive
        Any ->
            case Any of
                {next_request,Req,Head} ->
                    %% sent from request_target
                    case send(Sock, http11_res:encode(Head)) of
                        ok ->
                            %% get ready to stream the next one
                            request_target:need_request(Pid),
                            http11_res:push(Stm, Req, Head),
                            P = pipipe:push(Req, P0),
                            loop_tick(Pid, Sock, P, Clock, Stm);
                        closed ->
                            stop(Pid, Sock, P0, Clock, Stm, closed)
                    end;
                {body,Req,done} ->
                    P = flush(Pid, Sock, pipipe:close(Req, P0)),
                    %%Clock1 = case pipipe:is_empty(P) of
                    %%             true -> clock_stop(Clock);
                    %%             false -> clock_restart(Clock)
                    %%         end,
                    loop(Pid, Sock, P, Clock, Stm);
                {body,Req,Body} ->
                    P = pipipe:append(Req, Body, P0),
                    loop_tick(Pid, Sock, P, Clock, Stm);
                {tcp, _, <<>>} ->
                    loop_tick(Pid, Sock, P0, Clock, Stm);
                {tcp, _Sock, Data} ->
                    %%?DBG("tcp/read", [{res_pid,Stm},{data,Data}]),
                    http11_res:read(Stm, Data),
                    loop_tick(Pid, Sock, P0, Clock, Stm);
                {ssl, _, <<>>} ->
                    loop_tick(Pid, Sock, P0, Clock, Stm);
                {ssl, _Sock, Data} ->
                    %%?DBG("ssl/read", [{res_pid,Stm},{data,Data}]),
                    http11_res:read(Stm, Data),
                    loop_tick(Pid, Sock, P0, Clock, Stm);
                {tcp_closed,_} -> % closed must be placed after {tcp,_,_}
                    stop(Pid, Sock, P0, Clock, Stm, closed),
                    loop(Pid, Sock, P0, Clock, Stm);
                {ssl_closed,_} ->
                    stop(Pid, Sock, P0, Clock, Stm, closed),
                    loop(Pid, Sock, P0, Clock, Stm);
                {tcp_error,Reason} ->
                    ?DBG("loop", [{tcp_error,Reason}]),
                    stop(Pid, Sock, P0, Clock, Stm, Reason);
                {ssl_error,Reason} ->
                    ?DBG("loop", [{ssl_error,Reason}]),
                    stop(Pid, Sock, P0, Clock, Stm, Reason);
                heartbeat ->
                    clock_check(Clock), % does exit(timeout) if a timeout occurs
                    loop(Pid, Sock, P0, Clock, Stm);
                _ ->
                    exit({unknown_msg,Any})
            end
    end.

loop_tick(Pid, Sock, P, Clock, Stm) ->
    loop(Pid, Sock, P, Clock, Stm).
    %%loop(Pid, Sock, P, clock_restart(Clock), Stm).

stop(Pid, Sock, P, Clock, Stm, Reason) ->
    %%?DBG("stop", [{stm_pid,Stm},{reason,Reason}]),
    http11_res:close(Pid, Reason),
    loop(Pid, Sock, P, Clock, Stm).

%%% Keep a timer to check if we have timed-out on sending/receiving requests.

clock_restart(null) ->
    {ok,Timer} = timer:send_interval(100, heartbeat),
    {system_time(),Timer};

clock_restart({_,Timer}) ->
    {system_time(),Timer}.

clock_stop({_,Timer}) ->
    case timer:cancel(Timer) of
        {ok,cancel} ->
            null;
        {error,Rsn} ->
            error(Rsn)
    end.

clock_check(null) ->
    ok;

clock_check({LastRecv,_}) ->
    Delta = convert_time_unit(system_time() - LastRecv,
                              native, millisecond),
    if
        Delta > ?REQUEST_TIMEOUT ->
            exit(timeout);
        true ->
            ok
    end.

%%% sending data over sockets
%%%

send({tcp,Sock}, Data) ->
    case gen_tcp:send(Sock, Data) of
        {error,closed} ->
            closed;
        {error,Reason} ->
            exit(Reason);
        ok -> ok
    end;

send({ssl,Sock}, Data) ->
    case ssl:send(Sock, Data) of
        {error,closed} ->
            closed;
        {error,Reason} ->
            exit(Reason);
        ok -> ok
    end.

flush(Pid, Sock, P0) ->
    case pipipe:pop(P0) of
        not_done ->
            P0;
        {Req,Chunks,P} ->
            %%?DBG("flush", [{req,Req}]),
            foreach(fun (Chunk) -> send(Sock, Chunk) end, Chunks),
            flush(Pid, Sock, P)
    end.
