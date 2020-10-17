-module(outbound).

-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-import(erlang, [system_time/0, convert_time_unit/3]).

-export([connect/3, new_request/1, start/3]).

%%%
%%% EXTERNAL FUNCTIONS
%%%

connect(http, Host, Port) ->
    ?DBG("connect", {http,Host,Port}),
    spawn_link(fun () -> start(binary_to_list(Host), Port, false) end);

connect(https, Host, Port) ->
    ?DBG("connect", {https,Host,Port}),
    spawn_link(fun () -> start(binary_to_list(Host), Port, true) end).

%% notify the outbound Pid that a new request is ready for it to send/recv
new_request(Pid) ->
    Pid ! new_request,
    ok.

%%%
%%% INTERNAL FUNCTIONS
%%%

start(Host, Port, false) ->
    case gen_tcp:connect(Host, Port, [{active,true},binary,{packet,0}],
                         ?CONNECT_TIMEOUT) of
        {error, Reason} -> exit(Reason);
        {ok, Sock} ->
            start2({tcp,Sock})
    end;

start(Host, Port, true) ->
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0}],
                     ?CONNECT_TIMEOUT) of
        {error,Reason} -> exit(Reason);
        {ok,Sock} ->
            ssl:setopts(Sock, [{active,true}]),
            start2({ssl,Sock})
    end.

start2(Sock) ->
    {ok,Timer} = timer:send_interval(100, heartbeat),
    M = http11_stream,
    {ok,S} = M:new([http11_res, []]),
    loop(Sock, {system_time(),Timer}, M, S).

loop(Sock, Clock, M, S0) ->
    receive
        new_request ->
            case request_handler:next_request() of
                null ->
                    ?LOG_WARNING("request_handler lied about having a new_request!"),
                    loop(Sock, Clock, M, S0);
                {error,Rsn} ->
                    exit(Rsn);
                {ok, {Req,Head}=T} ->
                    morgue:listen(Req),
                    send(Sock, M:encode(S0, Head)),
                    %% append the req id/head to the queue
                    S = M:swap(S0, fun ({Dc,L}) -> {Dc,L++[T]} end),
                    loop(Sock, note_time(Clock), M, S)
            end;
        {body, Req, done} ->
            morgue:forget(Req),
            loop(Sock, Clock, M, S0);
        {body, _Req, Body} ->
            send(Sock, Body),
            loop(Sock, note_time(Clock), M, S0);
        {tcp_closed, _} ->
            exit(closed); % do not exit normal
        {ssl_closed, _} ->
            exit(closed);
        {tcp_error, Reason} ->
            exit(Reason);
        {ssl_error, Reason} ->
            exit(Reason);
        {tcp, _, <<>>} ->
            loop(Sock, Clock, M, S0);
        {tcp, _Sock, Data} ->
            stream(Sock, Clock, M, S0, Data);
        {ssl, _, <<>>} ->
            loop(Sock, Clock, M, S0);
        {ssl, _Sock, Data} ->
            stream(Sock, Clock, M, S0, Data);
        heartbeat ->
            heart_check(Clock), % exits if a timeout occurs
            loop(Sock, Clock, M, S0);
        Any ->
            exit({unknown_msg,Any})
    end.

stream(Sock, Clock, M, S0, Data) ->
    case M:read(S0, Data) of
        shutdown ->
            shutdown(Sock, write),
            WS = write_stream,
            loop(Sock, note_time(Clock), WS, WS:new(M));
        {ok,S} ->
            loop(Sock, note_time(Clock), M, S)
    end.

%% Updates the time of last recv.
note_time({_,Timer}) ->
    {system_time(),Timer}.

heart_check({LastRecv,_}) ->
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

shutdown({tcp,Sock}, Dir) ->
    ok = gen_tcp:shutdown(Sock, Dir);

shutdown({ssl,Sock}, Dir) ->
    ok = ssl:shutdown(Sock, Dir).

send({tcp,Sock}, Data) ->
    case gen_tcp:send(Sock, Data) of
        {error,Reason} -> exit(Reason);
        ok -> ok
    end;

send({ssl,Sock}, Data) ->
    case ssl:send(Sock, Data) of
        {error,Reason} -> exit(Reason);
        ok -> ok
    end.
