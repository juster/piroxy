-module(piserver).

-include("../include/phttp.hrl").
-import(lists, [foreach/2]).

-export([start/2, superserver/1, server/0, listen/2]).

start(Addr, Port) ->
    register(piserver, spawn(?MODULE, listen, [Addr,Port])).

listen(Addr, Port) ->
    case gen_tcp:listen(Port, [inet,{active,false},binary]) of
        {ok,Listen} ->
            superserver(Listen);
        {error,Reason} ->
            exit(Reason)
    end.

superserver(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok,Socket} ->
            Pid = spawn(fun ?MODULE:server/0),
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! {start,Socket},
                    superserver(Listen);
                {error,_}=Err ->
                    exit(Pid, kill),
                    Err
            end,
            ok;
        {error,Reason} ->
            exit(Reason)
    end.

server() ->
    receive
        {start,Socket} ->
            inet:setopts(Socket, [{active,true}]),
            Reader = pimsg:head_reader(),
            {ok,InPid} = inbound_stream:start_link(),
            ok = loop({tcp,Socket}, InPid, head, Reader),
            inbound:stop(InPid)
    end.

loop(Socket, InPid, HttpState, Reader) ->
    receive
        %% receive requests from the client and parse them out
        {tcp,_,Data} ->
            %%?DBG("loop", tcp),
            recv(Socket, InPid, HttpState, Reader, Data);
        {tcp_closed,_Sock} ->
            %% TODO: flush buffers etc
            %%?DBG("loop", tcp_closed),
            ok;
        {tcp_error,_Sock,Reason} ->
            exit(Reason);
        {ssl,_,Data} ->
            %%?DBG("loop", ssl),
            recv(Socket, InPid, HttpState, Reader, Data);
        {ssl_closed,_TlsSock} ->
            %% TODO: flush buffers etc
            %%?DBG("loop", ssl_closed),
            ok;
        {ssl_error,_Sock,Reason} ->
            exit(Reason);
        {respond,#head{}=Head} ->
            send_head(Socket, Head),
            loop(Socket, InPid, HttpState, Reader);
        {respond,{body,?EMPTY}} ->
            loop(Socket, InPid, HttpState, Reader);
        {respond,{body,Body}} ->
            send(Socket, Body),
            loop(Socket, InPid, HttpState, Reader);
        {respond,{error,Reason}} ->
            send(Socket, [error_statusln(Reason),<<?CRLF,?CRLF>>]),
            exit(Reason);
        {respond,close} ->
            loop(Socket, InPid, HttpState, Reader);
        {respond,disconnect} ->
            %% XXX: not sure why this is not received, maybe the socket is
            %% closed remotely first?
            ?DBG("loop", disconnect),
            %% We pass Socket around simple for this reason!
            case Socket of
                {tcp,Sock} -> gen_tcp:shutdown(Sock, write);
                {tls,Sock} -> ssl:shutdown(Sock, write)
            end,
            loop(Socket, InPid, HttpState, Reader);
        Msg ->
            ?DBG("loop", {unknown_msg,Msg}),
            loop(Socket, InPid, HttpState, Reader)
    end.

recv(Socket, InPid, HttpState, Reader, ?EMPTY) ->
    loop(Socket, InPid, HttpState, Reader);

recv(Socket, InPid, ignore, FakeReader, _) ->
    loop(Socket, InPid, ignore, FakeReader);

recv(Socket, InPid, head, Reader0, Data) ->
    case pimsg:head_reader(Reader0, Data) of
        {error,_} = Err -> Err;
        {continue,Reader} ->
            loop(Socket, InPid, head, Reader);
        {done,Line,Headers,Rest} ->
            head_end(Socket, InPid, Line, Headers, Rest)
    end;

recv(Socket, InPid, body, Reader0, Data) ->
    case pimsg:body_reader(Reader0, Data) of
        {error,_} = Err -> Err;
        {continue,Reader,Bin} ->
            inbound_stream:stream_request(InPid, Bin),
            recv(Socket, InPid, body, Reader, Bin);
        {done,?EMPTY,Rest} ->
            %% skip sending stream_request message
            inbound_stream:finish_request(InPid),
            Reader = pimsg:head_reader(),
            recv(Socket, InPid, head, Reader, Rest);
        {done,Bin,Rest} ->
            inbound_stream:stream_request(InPid, Bin),
            inbound_stream:finish_request(InPid),
            Reader = pimsg:head_reader(),
            recv(Socket, InPid, head, Reader, Rest)
    end.

recv_abort(Socket, InPid) ->
    inbound_stream:disconnect(InPid),
    loop(Socket, InPid, ignore, null).

head_end(Socket, InPid, Line, Headers, Rest) ->
    case request_head(Line, Headers) of
        {error,Reason} ->
            reflect_error(InPid, Reason),
            ?DBG("head_end", {error,Reason}),
            recv_abort(Socket, InPid);
        {ok,Head} ->
            body_begin(Socket, InPid, Head, Rest)
    end.

body_begin(Socket, InPid, Head0, Rest) ->
    ?DBG("body_begin", Head0),
    case request_target(Head0) of
        {error,Reason} ->
            reflect_error(InPid, Reason),
            ?DBG("body_begin", {error,Reason}),
            recv_abort(Socket, InPid);
        {ok,options_star} ->
            %% TODO: figure out what OPTIONS to send back
            reflect_status(InPid, http_ok);
        {ok,{null,_RelUri}} ->
            {ok,_Ref} = inbound:new(InPid, null, Head0),
            Reader = pimsg:body_reader(Head0#head.bodylen),
            recv(Socket, InPid, body, Reader, Rest);
        {ok,{HostInfo,Uri}} ->
            case Head0#head.method of
                connect ->
                    ?DBG("body_begin", connect),
                    inbound_stream:force_host(InPid, HostInfo),
                    tunnel(Socket, InPid, Rest, HostInfo);
                _ ->
                    case relativize(Uri, Head0) of
                        {error,Reason} ->
                            reflect_error(InPid, Reason),
                            ?DBG("body_begin", {error,Reason}),
                            recv_abort(Socket, InPid);
                        {ok,Head} ->
                            {ok,_Ref} = inbound:new(InPid, HostInfo, Head), % ignore Ref
                            Reader = pimsg:body_reader(Head#head.bodylen),
                            recv(Socket, InPid, body, Reader, Rest)
                    end
            end
    end.

relativize(Uri, Head0) ->
    case http_uri:parse(Uri) of
        {error,{malformed_uri,_,_}} ->
            {error,http_bad_request};
        {error,_} = Err ->
            Err;
        {ok,{_Scheme,_UserInfo,Host,_Port,Path0,Query}} ->
            case check_host(Host, Head0#head.headers) of
                {error,_} = Err -> Err;
                ok ->
                    MethodBin = phttp:method_bin(Head0#head.method),
                    Path = iolist_to_binary([Path0|Query]),
                    Line = <<MethodBin/binary, " ", Path/binary, " ", ?HTTP11>>,
                    {ok,Head0#head{line=Line}}
            end
    end.

% Returns:
%  {ok,#head{}} on success
%  {error,Reason} on error
%
request_head(Line, Headers) ->
    {ok,[MethodBin,_UriBin,VerBin]} = phttp:nsplit(3, Line, <<" ">>),
    case {phttp:method_atom(MethodBin), phttp:version_atom(VerBin)} of
        {unknown,_} ->
            ?DBG("request_head", {unknown_method,MethodBin}),
            {error,http_bad_request};
        {_,unknown} ->
            ?DBG("request_head", {unknown_version,VerBin}),
            {error,http_bad_request};
        {Method,Ver} ->
            case pimsg:request_length(Method, Headers) of
                {error,missing_length} ->
                    {error,http_bad_request};
                {ok,BodyLen} ->
                    {ok,#head{line=Line, method=Method, version=Ver,
                              headers=Headers, bodylen=BodyLen}}
            end
    end.

%% Returns HostInfo ({Host,Port}) for the provided request HTTP message header.
%% If the Head contains a request to a relative URI, Host=null.
request_target(Head) ->
    %% XXX: splits the request line twice (in request_head as well)
    {ok,[_,UriBin,_]} = phttp:nsplit(3, Head#head.line, <<" ">>),
    case {Head#head.method, UriBin} of
        {connect,_} ->
            {ok,[Host,Port]} = phttp:nsplit(2, UriBin, <<":">>),
            %% TODO: check what the schema is and IMPLEMENT TLS MITM FML!!!
            case Port of
                <<"443">> -> {ok,{{https,Host,binary_to_integer(Port)},UriBin}};
                <<"80">> -> {ok,{{http,Host,binary_to_integer(Port)},UriBin}};
                _ -> {error,http_bad_request}
            end;
        {options,<<"*">>} ->
            {ok,options_star};
        {_,<<"/",_/binary>>} ->
            %% relative URI, hopefully we are already CONNECT-ed to a
            %% single host
            {ok,{null,UriBin}};
        _ ->
            case http_uri:parse(UriBin) of
                {error,{malformed_uri,_,_}} ->
                    {error, http_bad_request};
                {ok,{Scheme,_UserInfo,Host,Port,_Path0,_Query}} ->
                    %% XXX: never Fragment?
                    %% XXX: how to use UserInfo?
                    %% URI should be absolute when received from proxy client!
                    %% Convert to relative before sending to host.
                    HostInfo = {Scheme,Host,Port},
                    {ok,{HostInfo,UriBin}}
            end
    end.

check_host(Host, Headers) ->
    case fieldlist:get_value(<<"host">>, Headers) of
        not_found ->
            {error,missing_host};
        Host ->
            ok;
        Host2 ->
            ?DBG("check_host", {host_mismatch,Host,Host2}),
            {error,{host_mismatch,Host2}}
    end.

send({tcp,Sock}, Data) ->
    gen_tcp:send(Sock, Data);

send({ssl,Sock}, Data) ->
    ssl:send(Sock, Data).

send_head(Socket, Head) ->
    send(Socket, [Head#head.line|<<?CRLF>>]),
    send(Socket, fieldlist:to_binary(Head#head.headers)),
    send(Socket, <<?CRLF>>),
    ok.

error_statusln(Reason) ->
    case phttp:status_bin(Reason) of
        {ok,Bin} ->
            Bin;
        not_found ->
            {ok,Bin} = phttp:status_bin(http_server_error),
            Bin
    end.

reflect_status(InPid, HttpStatus) ->
    case phttp:status_bin(HttpStatus) of
        {ok,Bin} ->
            reflect_statusln(InPid, Bin);
        not_found ->
            exit(badarg)
    end.

reflect_error(InPid, Reason) ->
    inbound_stream:reflect(InPid, [{error,Reason}]).

reflect_statusln(InPid, StatusBin) ->
    StatusLn = <<?HTTP11," ",StatusBin/binary>>,
    Head = #head{line=StatusLn, bodylen=0},
    inbound_stream:reflect(InPid, [Head]).

%% XXX: client can keep CONNECT-ing to new hosts indefinitely...
%% TODO: should I discard Rest?
%% TODO: handle ssl sockets as well?
tunnel({tcp,TcpSock}, InPid, Rest, {https,Host,443}) ->
    ?DBG("tunnel",{rest,Rest,host,Host,sock,TcpSock}),
    try
        ok = inet:setopts(TcpSock, [{active,false}]),
        {ok,StatusBin} = phttp:status_bin(http_ok),
        Resp = <<?HTTP11," ",StatusBin/binary,?CRLF,?CRLF>>,
        gen_tcp:send(TcpSock, Resp),
        case forger:forge(Host) of
            {error,_}=Err1 -> throw(Err1);
            {ok,{HostCert,Key,_CaCert}} ->
                %%?DBG("tunnel", {cert,HostCert}),
                %%DerCaCert = public_key:der_encode('Certificate',CaCert),
                DerKey = public_key:der_encode('ECPrivateKey', Key),
                ok = file:write_file("lastcert.pem",
                                     public_key:pem_encode([{'Certificate',HostCert,not_encrypted}])),
                Opts = [{mode,binary},{packet,0},{verify,verify_none},
                        {alpn_preferred_protocols,[<<"http/1.1">>]},
                        {cert,HostCert},{key,{'ECPrivateKey',DerKey}}],
                %%inet:controlling_process(TcpSock, self()),
                case ssl:handshake(TcpSock, Opts) of
                    {error,_}=Err2 -> throw(Err2);
                    {ok,TlsSock} ->
                        ?DBG("tunnel", {handshake,ok}),
                        %% XXX: active does not always work when provided to handshake/2
                        ssl:setopts(TlsSock, [{active,true}]),
                        Reader = pimsg:head_reader(),
                        ok = loop({ssl,TlsSock}, InPid, head, Reader),
                        throw(cleanup)
                end
        end
    catch
        cleanup ->
            %%?DBG("tunnel", cleanup),
            gen_tcp:close(TcpSock), % not sure how else to cleanup
            ok;
        {error,Reason} ->
            ?DBG("tunnel", {error,Reason}),
            reflect_error(InPid, Reason),
            recv_abort({tcp,TcpSock}, InPid)
    end.

