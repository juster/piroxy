-module(pipipe).

-export([new/0, push/2, pop/1, close/2, reset/1]).

new() ->
    [].

push(X, L) ->
    L ++ [{X,wait}].

pop([]) ->
    not_done;

pop([{_,wait}|_]) ->
    not_done;

pop([{X,done}|L]) ->
    {X,L}.

close(X, L) ->
    lists:keyreplace(X, 1, L, {X,done}).

reset(L) ->
    [{X,wait} || {X,_} <- L].
