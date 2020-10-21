-module(outbound).

-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-import(erlang, [system_time/0, convert_time_unit/3]).

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
    case gen_tcp:connect(Host, Port, [{active,true},binary,{packet,0}],
                         ?CONNECT_TIMEOUT) of
        {error, Reason} -> exit(Reason);
        {ok, Sock} ->
            start2(Pid, {tcp,Sock})
    end;

start(Pid, Host, Port, true) ->
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0}],
                     ?CONNECT_TIMEOUT) of
        {error,Reason} -> exit(Reason);
        {ok,Sock} ->
            ssl:setopts(Sock, [{active,true}]),
            start2(Pid, {ssl,Sock})
    end.

start2(Pid, Sock) ->
    M = http11_stream,
    {ok,S} = M:new([http11_res, []]),
    request_target:need_request(Pid),
    loop(Pid, Sock, [], null, {M,S}).

loop(Pid, Sock, Q0, Clock, Stream) ->
    receive
        {next_request,Req,Head} ->
            %% sent from request_target
            {M,S0} = Stream,
            send(Sock, M:encode(S0, Head)),
            %% append the req id/head to the queue (kind of sucky)
            S = M:swap(S0, fun ({Dc,L}) -> {Dc,L ++ [{Req,Head}]} end),
            request_target:need_request(Pid), % get ready to stream the next one
            Q = Q0 ++ [Req],
            loop(Pid, Sock, Q, clock_restart(Clock), {M,S});
        {tcp_closed,_} ->
            ok;
        {ssl_closed,_} ->
            ok;
        {body,Req,done} ->
            case Q0 of
                [] ->
                    error(underrun);
                [Req|Q] ->
                    request_target:close_request(Pid, Req),
                    Clock1 = case Q of
                                 [] -> clock_stop(Clock);
                                 _ -> clock_restart(Clock)
                             end,
                    loop(Pid, Sock, Q, Clock1, Stream);
                _ ->
                    error(overrun)
            end;
        {body,_Req,Body} ->
            send(Sock, Body),
            loop(Pid, Sock, Q0, clock_restart(Clock), Stream);
        {tcp_error,Reason} ->
            exit(Reason);
        {ssl_error,Reason} ->
            exit(Reason);
        {tcp, _, <<>>} ->
            loop(Pid, Sock, Q0, clock_restart(Clock), Stream);
        {tcp, _Sock, Data} ->
            stream(Pid, Sock, Q0, Clock, Stream, Data);
        {ssl, _, <<>>} ->
            loop(Pid, Sock, Q0, clock_restart(Clock), Stream);
        {ssl, _Sock, Data} ->
            stream(Pid, Sock, Q0, Clock, Stream, Data);
        heartbeat ->
            clock_check(Clock), % does exit(timeout) if a timeout occurs
            loop(Pid, Sock, Q0, clock_restart(Clock), Stream);
        Any ->
            exit({unknown_msg,Any})
    end.

stream(Pid, Sock, Q, Clock, {M,S0}, Data) ->
    case M:read(S0, Data) of
        shutdown ->
            %% Don't worry, request_target will resend requests which did
            %% not receive a response, yet.
            shutdown(Sock, write),
            WS = write_stream,
            loop(Pid, Sock, Q, clock_restart(Clock), {WS,WS:new(M)});
        {ok,S} ->
            loop(Pid, Sock, Q, clock_restart(Clock), {M,S})
    end.

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
