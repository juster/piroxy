-module(test_client).

-export([start/0, stop/0, get/1]).

start() ->
    {ok,Pid} = inbound_static:start_link(),
    register(test_inbound, Pid),
    {ok,Pid}.

stop() ->
    gen_server:stop(test_inbound).

get(Uri) ->
    {ok, {http,_,Host,Port,Path,Query}} = http_uri:parse(Uri),
    Headers = lists:foldl(fun ({K,V}, FL) ->
                                  fieldlist:add_value(K, V, FL)
                          end, [],
                          [{"host",Host}, {"accept-encoding", "identity"}]),
    {ok,Response} = inbound_static:send(test_inbound, {Host,Port}, {get, Path++Query, Headers}),
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
