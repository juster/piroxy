-module(write_stream).

-export([new/1, swap/2, read/2, encode/2]).

new([M]) ->
    M.

swap(M, _) ->
    M.

read(State, _) ->
    {ok,State}.

encode(M, Any) ->
    M:encode(Any).
