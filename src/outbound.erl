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
    {ok,Stm} = http11_res:new(),
    request_target:need_request(Pid),
    loop(Pid, Sock, pipipe:new(), null, Stm).

loop(Pid, Sock, P0, Clock, Stm) ->
    receive
        {next_request,Req,Head} ->
            %% sent from request_target
            send(Sock, http11_res:encode(Head)),
            http11_res:push(Stm, Req, Head),
            request_target:need_request(Pid), % get ready to stream the next one
            P = pipipe:push(Req, P0),
            loop_tick(Pid, Sock, P, Clock, Stm);
        {tcp_closed,_} ->
            ok;
        {ssl_closed,_} ->
            ok;
        {body,Req,done} ->
            P = flush(Pid, Sock, pipipe:close(Req, P0)),
            Clock1 = case pipipe:is_empty(P) of
                         true -> clock_stop(Clock);
                         false -> clock_restart(Clock)
                     end,
            loop(Pid, Sock, P, Clock1, Stm);
        {body,Req,Body} ->
            P = pipipe:append(Req, Body, P0),
            loop_tick(Pid, Sock, P, Clock, Stm);
        {tcp_error,Reason} ->
            exit(Reason);
        {ssl_error,Reason} ->
            exit(Reason);
        {tcp, _, <<>>} ->
            loop_tick(Pid, Sock, P0, Clock, Stm);
        {tcp, _Sock, Data} ->
            http11_res:read(Stm, Data),
            loop_tick(Pid, Sock, P0, Clock, Stm);
        {ssl, _, <<>>} ->
            loop_tick(Pid, Sock, P0, Clock, Stm);
        {ssl, _Sock, Data} ->
            http11_res:read(Stm, Data),
            loop_tick(Pid, Sock, P0, Clock, Stm);
        heartbeat ->
            clock_check(Clock), % does exit(timeout) if a timeout occurs
            loop(Pid, Sock, P0, Clock, Stm);
        Any ->
            exit({unknown_msg,Any})
    end.

loop_tick(Pid, Sock, P, Clock, Stm) ->
    loop(Pid, Sock, P, clock_restart(Clock), Stm).

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
        {error,Reason} -> exit(Reason);
        ok -> ok
    end;

send({ssl,Sock}, Data) ->
    case ssl:send(Sock, Data) of
        {error,Reason} -> exit(Reason);
        ok -> ok
    end.

flush(Pid, Sock, P0) ->
    case pipipe:pop(P0) of
        not_done ->
            P0;
        {Req,Chunks,P} ->
            foreach(fun (Chunk) -> send(Sock, Chunk) end, Chunks),
            request_target:close_request(Pid, Req),
            flush(Pid, Sock, P)
    end.
