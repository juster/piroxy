-module(test).
-import(piclient, [send/2,dumprecv/0]).

-export([start/0,send_stream/0]).

start() ->
    piclient:start().

send_stream() ->
    send(get, "https://duckduckgo.com"),
    send(get, "http://ipecho.net/plain"),
    dumprecv(),
    dumprecv().
