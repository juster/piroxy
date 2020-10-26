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
    {ok,Pid} = http11_req:start_link(),
    receive
        {start,TcpSock} ->
            inet:setopts(TcpSock, [{active,true}]),
            loop({tcp,TcpSock}, http11_req, Pid),
            http11_req:stop(Pid)
    end.

loop(Sock, Stream, State) ->
    receive
        %% receive requests from the client and parse them out
        {tcp,_,Data} ->
            stream(Sock, Stream, State, Data);
        {tcp_closed,_} ->
            %% TODO: flush buffers etc
            ok;
        {tcp_error,_,Reason} ->
            exit(Reason);
        {ssl,_,Data} ->
            stream(Sock, Stream, State, Data);
        {ssl_closed,_} ->
            ok;
        {ssl_error,_,Reason} ->
            exit(Reason);
        {make_tunnel,HostInfo} ->
            %%?DBG("loop", [{msg,make_tunnel},{hostinfo,HostInfo}]),
            send(Sock, Stream:encode({status,http_ok})),
            case tunnel(Sock, HostInfo) of
                {ok,TlsSock} ->
                    loop({ssl,TlsSock}, Stream, State);
                {error,Reason} ->
                    exit(Reason)
            end;
        {respond,close} ->
            ?LOG_WARNING("~p received {respond,close}", [self()]),
            loop(Sock, Stream, State);
        {respond,Resp} ->
            case Resp of
                {error,_} ->
                    ?DBG("loop", [{msg,{respond,Resp}}]);
                _ ->
                    ok
            end,
            case Stream:encode(Resp) of
                empty -> ok;
                IoList -> send(Sock, IoList)
            end,
            loop(Sock, Stream, State);
        Any ->
            ?LOG_DEBUG("~p received unknown message: ~p", [self(),Any]),
            loop(Sock, Stream, State)
    end.

stream(Sock, Stream, State, <<>>) ->
    ?LOG_DEBUG("~p received an empty data binary over socket", [self()]),
    loop(Sock, Stream, State);

stream(Sock, M, S, Data) ->
    ok = M:read(S, Data),
    loop(Sock, M, S).

send({tcp,Sock}, Data) ->
    gen_tcp:send(Sock, Data);

send({ssl,Sock}, Data) ->
    ssl:send(Sock, Data).

shutdown({tcp,Sock}) ->
    gen_tcp:shutdown(Sock, write);

shutdown({ssl,Sock}) ->
    ssl:shutdown(Sock, write).

fail(Sock, M, _State, Reason) ->
    send(Sock, M:encode({error,Reason})),
    exit(Reason).

mitm(TcpSock, Host) ->
    case inet:setopts(TcpSock, [{active,false}]) of
        %% socket may have suddenly closed!
        {error,_}=Err1 -> throw(Err1);
        ok -> ok
    end,
    {HostCert,Key,_CaCert} = case forger:forge(Host) of
                                 {error,_}=Err2 -> throw(Err2);
                                 {ok,T} -> T
                             end,
    DerKey = public_key:der_encode('ECPrivateKey', Key),
    Opts = [{mode,binary}, {packet,0}, {verify,verify_none},
            {alpn_preferred_protocols,[<<"http/1.1">>]},
            {cert,HostCert}, {key,{'ECPrivateKey',DerKey}}],
    %%inet:controlling_process(TcpSock, self()),
    TlsSock = case ssl:handshake(TcpSock, Opts, ?CONNECT_TIMEOUT) of
                  {error,_}=Err3 -> throw(Err3);
                  {ok,X} -> X
              end,
    %% XXX: active does not always work when provided to handshake/2
    ssl:setopts(TlsSock, [{active,true}]),
    TlsSock.

%% TODO: handle ssl sockets as well? (allows nested CONNECTs)
%% TODO: allow ports other than 443?
tunnel({tcp,TcpSock}, {https,Host,443}) ->
    try
        TlsSock = mitm(TcpSock, Host),
        %%?LOG_INFO("~p SSL handshake successful", [self()]),
        {ok,TlsSock}
    catch
        {error,Rsn} = Err ->
            ?LOG_ERROR("~p mitm failed for ~s: ~p", [self(),
                                                                      Host, Rsn]),
            Err
    end.
