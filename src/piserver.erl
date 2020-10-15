-module(piserver).

-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").
-import(lists, [foreach/2]).

-export([start/2, stop/0, superserver/1, server/0, listen/2]).

start(Addr, Port) ->
    register(piserver, spawn(?MODULE, listen, [Addr,Port])).

stop() ->
    exit(whereis(piserver), stop),
    ok.

listen(_Addr, Port) ->
    case gen_tcp:listen(Port, [inet,{active,false},binary]) of
        {ok,Listen} ->
            ?MODULE:superserver(Listen);
        {error,Reason} ->
            io:format("~p~n",{error,Reason}),
            exit(Reason)
    end.

superserver(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok,Socket} ->
            Pid = spawn(fun piserver:server/0),
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
    receive
        {start,TcpSock} ->
            inet:setopts(TcpSock, [{active,true}]),
            {ok,InPid} = inbound_stream:start_link(),
            {ok,State} = http11_stream:new(http11_req, [InPid]),
            loop({tcp,TcpSock}, http11_stream, State),
            inbound:stop(InPid)
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
        {disconnect} ->
            shutdown(Sock),
            ignore(Sock, Stream, State);
        {respond,close} ->
            %% XXX: close messages should never get to this process
            error(internal);
            %%loop(Sock, Stream, State);
        {respond,Resp} ->
            send(Sock, Stream:encode(Resp)),
            loop(Sock, Stream, State);
        Any ->
            ?DBG("loop", {unknown_msg,Any}),
            loop(Sock, Stream, State)
    end.

stream(Sock, Stream, State, <<>>) ->
    loop(Sock, Stream, State);

stream(Sock, Stream0, State0, Data) ->
    case Stream0:read(State0, Data) of
        {ok,State} ->
            loop(Sock, Stream0, State);
        {error,_} ->
            %% ignore any new requests
            ignore(Sock, Stream0, State0);
        {tunnel,MA,HostInfo} ->
            %% XXX: tunnel may possibly switch stream protocols
            %% I am not sure if this is necessary...
            tunnel(Sock, {Stream0,State0}, MA, HostInfo);
        {upgrade,Stream,State} ->
            loop(Sock, Stream, State)
    end.

ignore(Sock, Stream, State) ->
    receive
        %% receive requests from the client and parse them out
        {tcp,_,_Data} ->
            ignore(Sock, Stream, State);
        {tcp_closed,_} ->
            %% TODO: flush buffers etc
            ok;
        {tcp_error,_,Reason} ->
            exit(Reason);
        {ssl,_,_Data} ->
            ignore(Sock, Stream, State);
        {ssl_closed,_} ->
            ok;
        {ssl_error,_,Reason} ->
            exit(Reason);
        {disconnect} ->
            shutdown(Sock),
            ignore(Sock, Stream, State);
        {respond,close} ->
            %% XXX: close messages should never get to this process
            error(internal);
            %%ignore(Sock, Stream, State);
        {respond,Resp} ->
            send(Sock, Stream:encode(Resp)),
            ignore(Sock, Stream, State);
        Any ->
            ?DBG("ignore", {unknown_msg,Any}),
            ignore(Sock, Stream, State)
    end.

send({tcp,Sock}, Data) ->
    gen_tcp:send(Sock, Data);

send({ssl,Sock}, Data) ->
    ssl:send(Sock, Data).

shutdown({tcp,Sock}) ->
    gen_tcp:shutdown(Sock, write);

shutdown({ssl,Sock}) ->
    ssl:shutdown(Sock, write).

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
    TlsSock = case ssl:handshake(TcpSock, Opts) of
                  {error,_}=Err3 -> throw(Err3);
                  {ok,X} -> X
              end,
    ?DBG("tunnel", {handshake,ok}),
    %% XXX: active does not always work when provided to handshake/2
    ssl:setopts(TlsSock, [{active,true}]),
    TlsSock.

%% TODO: handle ssl sockets as well? (allows nested CONNECTs)
%% TODO: allow ports other than 443?
tunnel({tcp,TcpSock}=Sock, {Proto0,State0}, {Proto,Args}, {https,Host,443}) ->
    Bin = Proto0:encode({status,http_ok}),
    ?DBG("tunnel", {statusln, Bin}),
    gen_tcp:send(TcpSock, Bin),
    try
        TlsSock = mitm(TcpSock, Host),
        %% We may switch stream protocol or just reset the last stream.
        case apply(Proto, new, Args) of
            {ok,State} ->
                ?DBG("tunnel", {proto,Proto,state,State}),
                loop({ssl,TlsSock}, Proto, State);
            {error,Rsn1} ->
                exit(Rsn1) % XXX: how to be more graceful?
        end
    catch
        {error,Rsn2} ->
            Proto0:fail(Rsn2, State0),
            ignore(Sock,Proto0,State0)
    end.
