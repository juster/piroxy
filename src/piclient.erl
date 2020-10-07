-module(piclient).
-include("../include/phttp.hrl").
-import(lists, [reverse/1]).

-export([start/0, stop/1]).
-export([send/3, send/4, sendw/3, sendw/4, recv/0]).
-export([dump/1, dumpsend/3, dumpsend/4, dumprecv/0]).
-export([param_body/1]).

start() ->
    request_manager:start(),
    {ok,Pid1} = inbound_block:start_link(),
    {ok,Pid2} = inbound_stream:start_link(),
    {Pid1,Pid2}.

stop({Pid1,Pid2}) ->
    gen_server:stop(Pid1),
    gen_server:stop(Pid2).

hostinfo({Schema,_,Host,Port,_,_}) ->
    {Schema,Host,Port};

hostinfo({Schema,_,Host,Port,_,_,_}) ->
    {Schema,Host,Port}.

default_headers(Method, UriT, ContentLen) ->
    Host = element(3, UriT) ++ ":" ++ integer_to_list(element(4, UriT)),
    PostHeaders = case Method of
                      post ->
                          [{"content-type",
                            "application/x-www-form-urlencoded"},
                           {"content-length",
                            integer_to_list(ContentLen)}];
                      _ -> []
                  end,
    fieldlist:from_proplist([{"host", Host},
                             {"accept-encoding", "identity"}]
                            ++ PostHeaders).

reluri({_,_,_,_,Path,Query}) ->
    Path++Query;

reluri({_,_,_,_,Path,Query,_}) ->
    Path++Query.

encode_params(Params) ->
    [{phttp:cent_enc(atom_to_list(K)), phttp:cent_enc(V)} || {K,V} <- Params].

param_body(Params) ->
    ParamsEnc = encode_params(Params),
    string:join([string:join([K, V], "=") || {K,V} <- ParamsEnc], "&").

request_line(Method, Uri) ->
    MethodBin = phttp:method_bin(Method),
    UriBin = iolist_to_binary(Uri),
    <<MethodBin/binary, " ", UriBin/binary, " ", ?HTTP11>>.

send_args(Method, Uri, Body) ->
    {ok,UriT} = http_uri:parse(Uri),
    CLength = case Body of ?EMPTY -> 0; _ -> iolist_size(Body) end,
    Headers = default_headers(Method, UriT, CLength),
    ReqHead = #head{method=Method, headers=Headers, bodylen=CLength,
                    line=request_line(Method, reluri(UriT))},
    HostInfo = hostinfo(UriT),
    {HostInfo, ReqHead}.

%% Send request and wait (block) for response.
sendw(Pids, Method, Uri) -> sendw(Pids, Method, Uri, ?EMPTY).

sendw({Pid,_}, Method, Uri, Body) ->
    {HostInfo, ReqHead} = send_args(Method, Uri, Body),
    inbound_block:send(Pid, HostInfo, ReqHead, Body).

%% Send request but do not wait for response. {respond,...} messages are
%% received by the piclient process.
send(Pids, Method, Uri) -> send(Pids, Method, Uri, ?EMPTY).

send({_,Pid}, Method, Uri, Body) ->
    {HostInfo, ReqHead} = send_args(Method, Uri, Body),
    _Req = inbound:new(Pid, HostInfo, ReqHead),
    case Body of
        ?EMPTY -> ok;
        _ -> inbound_stream:stream_request(piclient_stream, Body)
    end,
    inbound_stream:stream_request(piclient_stream, done),
    ok.

%% Wait to receive a single response from a request that was already sent.
recv() ->
    receive
        {respond,reset} ->
            recv();
        {respond,#head{}=Head} ->
            recv(Head, []);
        {respond,_} ->
            {error,expected_head}
    end.

recv(H, Body) ->
    receive
        {respond,reset} ->
            recv();
        {respond,#head{}} ->
            {error,expected_body};
        {respond,{body,Chunk}} ->
            recv(H, [Chunk|Body]);
        {respond,close} ->
            {ok,{H#head.line, H#head.headers, reverse(Body)}}
    end.

dump({ok,Res}) ->
    {StatusLn, ResHeaders, Body} = Res,
    %%io:format("*DBG* received response:~n~w~n", [{StatusLine, ResHeaders, Body}]),
    io:format("-{ STATUS }-------------------"
              "------------------------------~n"
              "~s~n"
              "-[ HEADERS ]------------------"
              "------------------------------~n~s",
              [StatusLn, fieldlist:to_iolist(ResHeaders)]),
    io:format("-< BODY >---------------------"
              "------------------------------~n~s~n"
              "------------------------------"
              "------------------------------~n",
              [Body]),
    ok.

dumpsend(Pids, Method, Uri) ->
    dump(sendw(Pids, Method, Uri)).

dumpsend(Pids, Method, Uri, Body) ->
    dump(sendw(Pids, Method, Uri, Body)).

dumprecv() ->
    dump(recv()).

