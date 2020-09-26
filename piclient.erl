-module(piclient).
-include("phttp.hrl").

-export([start/0, stop/0]).
-export([send/2, send/3, dump/1, dumpsend/2, dumpsend/3, param_body/1]).

start() ->
    request_manager:start_link(),
    inbound_static:start_link(piclient_inbound),
    ok.

stop() ->
    gen_server:stop(piclient_inbound).

dump({ok,Res}=Result) ->
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

hostinfo({Schema,_,Host,Port,_,_}) ->
    {Schema,Host,Port};

hostinfo({Schema,_,Host,Port,_,_,_}) ->
    {Schema,Host,Port}.

default_headers(UriT) ->
    lists:foldl(fun ({K,V}, FL) -> fieldlist:add_value(K, V, FL) end,
                [],
                [{"host", element(3, UriT)},
                 {"accept-encoding", "identity"}]).

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

send(Method, Uri) -> send(Method, Uri, ?EMPTY).

send(Method, Uri, Body) ->
    {ok,UriT} = http_uri:parse(Uri),
    CLength = case Body of ?EMPTY -> 0; _ -> iolist_size(Body) end,
    case CLength of
        0 -> Headers = default_headers(UriT);
        _ ->
            %% sends request bodies using smooth (not chunky) transfer
            %% encoding.
            Fun = fun ({K,V}, FL) -> fieldlist:add_value(K, V, FL) end,
            Headers = lists:foldl(Fun,
                                  default_headers(UriT),
                                  [{"content-type",
                                    "application/x-www-form-urlencoded"},
                                   {"content-length",
                                    integer_to_list(CLength)}])
    end,
    ReqHead = #head{method=Method, headers=Headers, bodylen=CLength,
                    line=request_line(Method, reluri(UriT))},
    HostInfo = hostinfo(UriT),
    inbound_static:send(piclient_inbound, HostInfo, ReqHead, Body).

dumpsend(Method, Uri) ->
    dump(send(Method, Uri)).

dumpsend(Method, Uri, Body) ->
    dump(send(Method, Uri, Body)).
