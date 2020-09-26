-module(piserver).

-compile(export_all).

-include("phttp.hrl").
-import(lists, [foreach/2]).

start(_Addr, Port) ->
    io:format("DING~n"),
    {ok,Listen} = gen_tcp:listen(Port, [inet,{active,true},binary]),
    register(piserver, spawn_link(?MODULE, superserver, [Listen])).

superserver(Listen) ->
    spawn_link(?MODULE, server, [self(), Listen]),
    receive
        started -> superserver(Listen)
    end.

server(Pid, Listen) ->
    {ok,Socket} = gen_tcp:accept(Listen),
    io:format("DANG~n"),
    Pid ! started,
    Reader = pimsg:head_reader(),
    {ok,InPid} = inbound_stream:start_link(),
    loop(Socket, InPid, head, Reader).

loop(Socket, InPid, HttpState, Reader) ->
    receive
        {tcp,_,Data} ->
            ?DBG("loop", {socket,Socket,httpState,HttpState,
                          data,Data}),
            recv(Socket, InPid, HttpState, Reader, Data);
        {tcp_closed, _Sock} ->
            io:format("*DBG* [loop] tcp_closed~n"),
            exit(normal);
        {tcp_error, _Sock, Reason} ->
            exit(Reason);
        {respond,{head,Head}} ->
            send_head(Socket, Head),
            loop(Socket, InPid, HttpState, Reader);
        {respond,{body,Body}} ->
            send_body(Socket, Body),
            loop(Socket, InPid, HttpState, Reader);
        {respond,close} ->
            loop(Socket, InPid, HttpState, Reader);
        disconnect ->
            %% XXX: not sure why this is not received, maybe the socket is
            %% closed remotely first?
            io:format("*DBG* [loop] disconnect~n"),
            gen_tcp:shutdown(Socket, write),
            loop(Socket, InPid, HttpState, Reader);
        Msg ->
            io:format("*DBG* [loop] UNK: ~p~n", [Msg]),
            loop(Socket, InPid, HttpState, Reader)
    end.

recv(Socket, InPid, ignore, FakeReader, _) ->
    loop(Socket, InPid, ignore, FakeReader);

recv(Socket, InPid, head, Reader, ?EMPTY) ->
    loop(Socket, InPid, head, Reader);

recv(Socket, InPid, head, Reader0, Data) ->
    case pimsg:head_reader(Reader0, Data) of
        {error,_} = Err -> Err;
        {continue,Reader} ->
            loop(Socket, InPid, head, Reader);
        {done,Line,Headers,Rest} ->
            head_end(Socket, InPid, Line, Headers, Rest)
    end;

recv(Socket, InPid, body, Reader, ?EMPTY) ->
    loop(Socket, InPid, body, Reader);

recv(Socket, InPid, body, Reader0, Data) ->
    case pimsg:body_reader(Reader0, Data) of
        {error,_} = Err -> Err;
        {continue,Reader,Bin} ->
            inbound_stream:receive_body(InPid, Bin),
            recv(Socket, InPid, body, Reader, Bin);
        {done,?EMPTY,Rest} ->
            %% skip sending receive_body message
            Reader = pimsg:head_reader(),
            recv(Socket, InPid, head, Reader, Rest);
        {done,Bin,Rest} ->
            inbound_stream:receive_body(InPid, Bin),
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
            recv_abort(Socket, InPid);
        {ok,Head} ->
            body_begin(Socket, InPid, Head, Rest)
    end.

body_begin(Socket, InPid, Head0, Rest) ->
    case request_target(Head0) of
        {error,Reason} ->
            reflect_error(InPid, Reason),
            recv_abort(Socket, InPid);
        {ok,{HostInfo,Uri}} ->
            case Head0#head.method of
                connect ->
                    reflect_error(InPid, http_not_implemented),
                    recv_abort(Socket, InPid);
                _ ->
                    case relativize(Uri, Head0) of
                        {error,Reason} ->
                            reflect_error(InPid, Reason),
                            recv_abort(Socket, InPid);
                        {ok,Head} ->
                            _Ref = inbound:new(InPid, HostInfo, Head), % ignore Ref
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
        {ok,{_Scheme,_UserInfo,Host,Port,Path0,Query}} ->
            case check_host(Host++[$:|Port], Head0#head.headers) of
                {error,_} = Err -> Err;
                ok ->
                    MethodBin = phttp:method_bin(Head0#head.method),
                    Path = iolist_to_binary([Path0|Query]),
                    Line = <<MethodBin/binary, " ", Path/binary, " ", ?HTTP11>>,
                    Head0#head{line=Line}
            end
    end.

% Returns:
%  {ok,{HostInfo,#head}} on success
%  {error,Reason} on error
%
request_head(Line, Headers) ->
    {ok,[MethodBin,_UriBin,VerBin]} = phttp:nsplit(3, Line, <<" ">>),
    case {phttp:method_atom(MethodBin), phttp:version_atom(VerBin)} of
        {unknown,_} ->
            {error,http_bad_request};
        {_,unknown} ->
            {error,http_bad_request};
        {Ver,Method} ->
            case pimsg:request_length(Method, Headers) of
                {error,missing_length} ->
                    {error,http_bad_request};
                {ok,BodyLen} ->
                    #head{line=Line, method=method, version=Ver,
                          headers=Headers, bodylen=BodyLen}
            end
    end.

%% Returns host info for the provided request HTTP message header.
request_target(Head) ->
    {ok,[_,UriBin,_]} = phttp:nsplit(3, Head#head.line, <<" ">>),
    case Head#head.method of
        connect ->
            {ok,[Host,Port]} = phttp:nsplit(2, UriBin, <<":">>),
            %% TODO: check what the schema is and IMPLEMENT TLS MITM FML!!!
            {ok,{https,Host,Port}};
        options ->
            %% TODO: parse URI and allow for asterisk (*)
            {error,http_not_implemented};
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
    case fieldlist:get(<<"Host">>, Headers) of
        not_found ->
            {error,missing_host};
        {ok,Host} ->
            ok;
        {ok,Host2} ->
            {error,{host_mismatch,Host2}}
    end.

send_head(Socket, Head) ->
    gen_tcp:send(Socket, [Head#head.line|<<?CRLF>>]),
    foreach(fun (Header) ->
                    Bin = fieldlist:to_binary(Header),
                    gen_tcp:send(Socket, [Bin|<<?CRLF>>])
            end, Head#head.headers),
    gen_tcp:send(Socket, <<?CRLF>>),
    ok.

send_body(Socket, Chunk) ->
    gen_tcp:send(Socket, Chunk),
    ok.

%% TODO: reflect_status equivalent?
reflect_error(InPid, Reason) ->
    StatusBin = case phttp:status_bin(Reason) of
                    {ok,Bin} -> Bin;
                    not_found ->
                        {ok,Bin} = phttp:status_bin(http_server_error),
                        Bin
                end,
    StatusLn = <<?HTTP11," ",StatusBin/binary>>,
    Head = #head{line=StatusLn, bodylen=0},
    inbound_stream:reflect(InPid, [{head,Head}]).

