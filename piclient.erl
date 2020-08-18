-module(piclient).

-export([start/0, stop/0]).
-export([hostinfo/1, headers/1, send/2, send/3, dump/1, param_body/1]).

start() ->
    request_manager:start_link(),
    case lists:member(piclient_inbound, registered()) of
        true ->
            ok;
        false ->
            {ok,Pid} = inbound_static:start_link(),
            register(piclient_inbound, Pid),
            ok
    end.

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

hostinfo(Uri) ->
    {ok, {Schema,_,Host,Port,_,_}} = http_uri:parse(Uri),
    {Schema,Host,Port}.

headers(Uri) ->
    {ok, UriT} = http_uri:parse(Uri),
    lists:foldl(fun ({K,V}, FL) -> fieldlist:add_value(K, V, FL) end,
                [],
                [{"host",element(3, UriT)},
                 {"accept-encoding", "identity"}]).

reluri(Uri) ->
    {ok, {_,_,_,_,Path,Query}} = http_uri:parse(Uri),
    Path++Query.

encode_params(Params) ->
    [{phttp:cent_enc(atom_to_list(K)), phttp:cent_enc(V)} || {K,V} <- Params].

param_body(Params) ->
    ParamsEnc = encode_params(Params),
    string:join([string:join([K, V], "=") || {K,V} <- ParamsEnc], "&").

send(Method, Uri) ->
    Headers = headers(Uri),
    HostInfo = hostinfo(Uri),
    Request = {Method, reluri(Uri), Headers},
    inbound_static:send(piclient_inbound, HostInfo, Request).

send(Method, Uri, Body) ->
    CLength = if
                  is_binary(Body) -> byte_size(Body);
                  is_list(Body) -> length(Body)
              end,
    HList = lists:reduce(fun ({K,V}, FL) -> fieldlist:add_value(K, V, FL) end,
                         headers(Uri),
                         [{"content-type", "application/x-www-form-urlencoded"},
                          {"content-length", integer_to_list(CLength)}]),
    send(hostinfo(Uri), {Method, reluri(Uri), HList}, Body).
