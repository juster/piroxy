-module(pipipe).

-export([new/0, is_empty/1, values/1, push/2, pop/1, append/3, close/2, reset/1]).

new() ->
    {[], dict:new()}.

is_empty({[],_}) ->
    true;

is_empty(_) ->
    false.

values({L,_}) ->
    [X || {X,_} <- L].

push(X, {L,D}) ->
    {L ++ [{X,wait}], dict:store(X, [], D)}.

pop({[],_}) ->
    not_done;

pop({[{_,wait}|_], _}) ->
    not_done;

pop({[{X,done}|L], D0}) ->
    case dict:take(X, D0) of
        error ->
            error(internal);
        {Y,D} ->
            {X,Y,{L,D}}
    end.

append(X, Y, {L,D}) ->
    {L, dict:append(X, Y, D)}.

close(X, {L,D}) ->
    {lists:keyreplace(X, 1, L, {X,done}), D}.

reset({L,_}) ->
    {Xs,_} = lists:unzip(L),
    {[{X,wait} || X <- Xs],
     dict:from_list([{X,[]} || X <- Xs])}.
