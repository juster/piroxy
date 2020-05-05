-module(piclient).

-export([start/0, stop/0, get/1, getout/1, post/2, postout/2]).

start() ->
    request_manager:start_link(),
    case lists:member(piclient_inbound, registered()) of
        true ->
            {ok,piclient_inbound};
        false ->
            {ok,Pid} = inbound_static:start_link(),
            register(piclient_inbound, Pid),
            {ok,piclient_inbound}
    end.

stop() ->
    gen_server:stop(piclient_inbound).

dump_body(Response) ->
    {StatusLine, ResHeaders, Body} = Response,
    %%io:format("*DBG* received response:~n~w~n", [{StatusLine, ResHeaders, Body}]),
    {{Major, Minor}, Status, _} = StatusLine,
    io:format("STATUS: ~s (HTTP ~B.~B)~nHEADERS~n~s"
              "------------------------------"
              "------------------------------~n",
              [Status, Major, Minor, fieldlist:to_iolist(ResHeaders)]),
    io:format("BODY:~n~s"
              "------------------------------"
              "------------------------------~n",
              [Body]),
    ok.

get(Uri) ->
    {ok, {Schema,_,Host,Port,Path,Query}} = http_uri:parse(Uri),
    Headers = lists:foldl(fun ({K,V}, FL) ->
                                  fieldlist:add_value(K, V, FL)
                          end, [],
                          [{"host",Host}, {"accept-encoding", "identity"}]),
    HostInfo = {Schema,Host,Port},
    Request = {get, Path++Query, Headers},
    inbound_static:send(piclient_inbound, HostInfo, Request).

getout(Uri) ->
    case ?MODULE:get(Uri) of
        {ok, Res} ->
            dump_body(Res);
        X ->
            X
    end.

encode_uri(X) ->
    Uri0 = http_uri:encode(X),
    Uri1 = re:replace(Uri0, "`", "%60", [global, {return, list}]),
    Uri2 = re:replace(Uri1, "\n", "%0A", [global, {return, list}]),
    Uri2.

encode_params(Params) ->
    Fun = fun ({K,V}) when is_list(V) ->
                  {http_uri:encode(atom_to_list(K)),
                   encode_uri(unicode:characters_to_list(V))};
              ({K,V}) when is_binary(V) ->
                  {http_uri:encode(atom_to_list(K)),
                   encode_uri(binary_to_list(V))};
              ({K,V}) when is_integer(V) ->
                  {http_uri:encode(atom_to_list(K)),
                   encode_uri(integer_to_list(V))}
          end,
    lists:map(Fun, Params).

param_body(Params) ->
    ParamsEnc = encode_params(Params),
    string:join([string:join([K, V], "=") || {K,V} <- ParamsEnc], "&").

post(Uri, Params) ->
    {ok, {Schema,_,Host,Port,Path,Query}} = http_uri:parse(Uri),
    ReqBody = param_body(Params),
    HList = [{"host", Host},
             {"accept-encoding", "identity"},
             {"content-type", "application/x-www-form-urlencoded"},
             {"content-length", integer_to_list(length(ReqBody))}],
    HostInfo = {Schema,Host,Port},
    ReqHead = {post, Path++Query, fieldlist:from_proplist(HList)},
    inbound_static:send(piclient_inbound, HostInfo, ReqHead, ReqBody).

postout(Uri, Params) ->
    case post(Uri, Params) of
        {ok, Res} ->
            dump_body(Res);
        X ->
            X
    end.
