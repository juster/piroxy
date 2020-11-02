-module(piserver).

-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").
-import(lists, [foreach/2]).

-export([start/2, start_link/2, stop/0, superserver/1, server/0, listen/2]).

start(Addr, Port) ->
    Pid = spawn(?MODULE, listen, [Addr,Port]),
    register(piserver, Pid),
    {ok,Pid}.

start_link(Addr, Port) ->
    Pid = spawn_link(?MODULE, listen, [Addr,Port]),
    register(piserver, Pid),
    {ok,Pid}.

stop() ->
    exit(whereis(piserver), stop),
    ok.

listen(_Addr, Port) ->
    case gen_tcp:listen(Port, [inet,{active,false},binary]) of
        {ok,Listen} ->
            superserver(Listen);
        {error,Reason} ->
            io:format("~p~n",{error,Reason}),
            exit(Reason)
    end.

superserver(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok,Socket} ->
            Pid = spawn(?MODULE, server, []),
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! {start,Socket},
                    piserver:superserver(Listen);
                {error,Reason} ->
                    exit(Pid, kill),
                    exit(Reason)
            end,
            ok;
        {error,Reason} ->
            exit(Reason)
    end.

server() ->
    response_handler:add_sup_handler(),
    {ok,Pid} = http11_req:start_link([]),
    receive
        {start,TcpSock} ->
            inet:setopts(TcpSock, [{active,true}]),
            loop({tcp,TcpSock}, http11_req, Pid),
            http11_req:stop(Pid)
    end.

loop(Sock, M, A) ->
    receive
        %% receive requests from the client and parse them out
        {tcp,_,Data} ->
            stream(Sock, M, A, Data);
        {tcp_closed,_} ->
            %% TODO: flush buffers etc
            M:shutdown(A, closed),
            loop(Sock, M, A);
        {tcp_error,_,Reason} ->
            M:shutdown(A, Reason),
            loop(Sock, M, A);
        {ssl,_,Data} ->
            stream(Sock, M, A, Data);
        {ssl_closed,_} ->
            M:shutdown(A, closed),
            loop(Sock, M, A);
        {ssl_error,_,Reason} ->
            M:shutdown(A, Reason);
        {make_tunnel,HostInfo} ->
            send(Sock, M:encode({status,http_ok})),
            TlsSock = tunnel(Sock, HostInfo),
            loop({ssl,TlsSock}, M, A);
        {upgrade_protocol,M2,InitArgs} ->
            ?DBG("loop", [upgrade_protocol, {module,M2}, {args,InitArgs}]),
            {ok,A2} = M2:start_link(InitArgs),
            loop(Sock, M2, A2);
        {stream,Resp} ->
            M:push(A, Sock, Resp),
            loop(Sock, M, A);
        Any ->
            exit({unknown_message, Any})
    end.

stream(Sock, M, A, <<>>) ->
    ?LOG_DEBUG("~p received an empty data binary over socket", [self()]),
    loop(Sock, M, A);

stream(Sock, M, A, Data) ->
    ok = M:read(A, Data),
    loop(Sock, M, A).

send({tcp,Sock}, Data) ->
    gen_tcp:send(Sock, Data);

send({ssl,Sock}, Data) ->
    ssl:send(Sock, Data).

%%shutdown({tcp,Sock}) ->
%%    gen_tcp:shutdown(Sock, write);
%%
%%shutdown({ssl,Sock}) ->
%%    ssl:shutdown(Sock, write).
%%
%%fail(Sock, M, _A, Reason) ->
%%    send(Sock, M:encode({error,Reason})),
%%    exit(Reason).

%% TODO: handle ssl sockets as well? (allows nested CONNECTs)
%% TODO: allow ports other than 443?
tunnel({tcp,TcpSock}, {https,Host,443}) ->
    case forger:mitm(TcpSock, Host) of
        {ok,TlsSock} ->
            TlsSock;
        {error,closed} ->
            exit(closed);
        {error,einval} ->
            exit(closed);
        {error,Rsn} ->
            ?LOG_ERROR("~p mitm failed for ~s: ~p", [self(), Host, Rsn]),
            exit(Rsn)
    end.
