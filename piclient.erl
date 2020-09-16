-module(piclient).

-export([start/0, stop/0]).
-export([send/2, send/3, dump/1, param_body/1]).

start() ->
    request_manager:start_link(),
    inbound_static:start_link(piclient_inbound),
    ok.

stop() ->
    gen_server:stop(piclient_inbound).

dump({ok,Res}=Result) ->
    dump_body(Res),
    Result;

dump(X) ->
    X.

dump_body(Response) ->
    {StatusLine, ResHeaders, Body} = Response,
    %%io:format("*DBG* received response:~n~w~n", [{StatusLine, ResHeaders, Body}]),
    {{Major, Minor}, Status, _} = StatusLine,
    io:format("-{ STATUS }-------------------"
              "------------------------------~n"
              "~s HTTP/~B.~B~n"
              "-[ HEADERS ]------------------"
              "------------------------------~n~s",
              [Status, Major, Minor, fieldlist:to_iolist(ResHeaders)]),
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

headers(UriT) ->
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

send(Method, Uri) ->
    {ok,UriT} = http_uri:parse(Uri),
    Headers = headers(UriT),
    HostInfo = hostinfo(UriT),
    Request = {Method, reluri(UriT), Headers},
    inbound_static:send(piclient_inbound, HostInfo, Request).

send(Method, Uri, Body) ->
    {ok,UriT} = http_uri:parse(Uri),
    CLength = if
                  is_binary(Body) -> byte_size(Body);
                  is_list(Body) -> length(Body)
              end,
    Headers = lists:foldl(fun ({K,V}, FL) -> fieldlist:add_value(K, V, FL) end,
                          headers(UriT),
                          [{"content-type",
                            "application/x-www-form-urlencoded"},
                           {"content-length",
                            integer_to_list(CLength)}]),
    HostInfo = hostinfo(UriT),
    Request = {Method, reluri(UriT), Headers},
    inbound_static:send(piclient_inbound, HostInfo, Request, Body).
