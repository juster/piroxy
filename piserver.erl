-module(piserver).

-compile(export_all).

-include("phttp.hrl").

-import(lists, [foreach/2]).

-define(RECVMAX, 1024).
-define(URLMAX, 256).

start(_Addr, Port) ->
    {ok,Listen} = gen_tcp:listen(Port, [inet,{active,true}]),
    {ok,Socket} = gen_tcp:accept(Listen),
    Reader = phttp:head_reader(),
    InPid = inbound_stream:start_link(),
    loop(Socket, InPid, head, Reader).

loop(Socket, InPid, HttpState, Reader) ->
    receive
        {tcp,_,Data} ->
            recv(Socket, InPid, HttpState, Reader, Data);
        {tcp_closed, _Sock} ->
            exit(tcp_closed);
        {tcp_error, _Sock, Reason} ->
            exit(Reason);
        {respond,{head,Head}} ->
            send_head(Socket, Head),
            loop(Socket, InPid, HttpState, Reader);
        {respond,{body,Body}} ->
            send_body(Socket, Body),
            loop(Socket, InPid, HttpState, Reader)
    end.

recv(Socket, InPid, head, Reader, ?EMPTY) ->
    loop(Socket, InPid, head, Reader);

recv(Socket, InPid, head, Reader0, Data) ->
    case phttp:head_reader(Reader0, Data) of
        {error,_} = Err -> Err;
        {continue,Reader} -> {ok,Reader};
        {done,Line,Headers,Rest} ->
            BodyLen = phttp:body_length(Headers),
            new_request(InPid, Line, Headers, BodyLen),
            Reader = phttp:body_reader(BodyLen),
            recv(Socket, InPid, body, Reader, Rest)
    end;

recv(Socket, InPid, body, Reader, ?EMPTY) ->
    loop(Socket, InPid, body, Reader);

recv(Socket, InPid, body, Reader0, Data) ->
    case phttp:body_reader(Reader0, Data) of
        {error,_} = Err -> Err;
        {continue,Reader,Bin} ->
            inbound_stream:receive_body(InPid, Bin),
            recv(Socket, InPid, body, Reader, Bin);
        {done,?EMPTY,Rest} ->
            %% skip sending receive_body message
            Reader = phttp:head_reader(),
            recv(Socket, InPid, head, Reader, Rest);
        {done,Bin,Rest} ->
            inbound_stream:receive_body(InPid, Bin),
            Reader = phttp:head_reader(),
            recv(Socket, InPid, head, Reader, Rest)
    end.

new_request(Pid, Line, Headers, BodyLen) ->
    %% may fail hard here
    {ok,[MethodBin,UriBin,<<"HTTP/1.1">>]} = phttp:nsplit(3, Line),
    Method = phttp:method_atom(MethodBin),
    case http_uri:parse(UriBin) of
        {error,Reason} ->
            exit({request_bad_uri,UriBin,Reason});
        {ok,{Scheme,UserInfo,Host,Port,Path0,Query}} ->
            %% XXX: never Fragment?
            %% XXX: how to use UserInfo?
            %% URI should be absolute when received from proxy client!
            %% Convert to relative before sending to host.
            HostInfo = {Scheme,Host,Port},
            Path = iolist_to_binary([Path0|Query]),
            Line = <<MethodBin/binary, " ", Path/binary, " ", ?HTTP11>>,
            Head = #head{method=Method, line=Line,
                         headers=Headers, bodylen=BodyLen},
            inbound:send(Pid, HostInfo, Head)
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

