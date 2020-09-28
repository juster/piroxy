-module(cbuf).

-export([new/1, count/1, is_empty/1, push/2, pop/1, top/1, bottom/1]).
-export([find/2, update/3, to_list/1]).

-import(lists, [reverse/1]).

%% Circular buffer queue functions
%% readi <= writei ... readi is trying to catch up to writei
%% readi > writei ... we are caught up and are currently idle
%% readi is the *next* read index
%% writei is the *next* store index
%% if readi >= writei then there are no pending sessions in the todo list
%% (but there may be one currently active)
%% if readi == writei then there is an active session in the todo list

new(Cap) when Cap =< 0 ->
    error(badarg);
new(Cap) ->
    {0,0,Cap,array:new([{size,Cap},fixed])}.

count({I,J,_,_}) -> J-I.

is_empty({I,J,_,_}) when I =:= J -> true;
is_empty(_) -> false.

push(_, {I,J,C,_}) when J-I >= C -> overflow;
push(X, {I,J,C,Arr}) ->
    {ok,{I,J+1,C,array:set(X, J rem C, Arr)}}.

pop({I,J,C,Arr} = T) ->
    case is_empty(T) of
        true -> empty;
        false -> {ok,{I+1,J,C,Arr}}
    end.

top({I,_,C,Arr} = T) ->
    case is_empty(T) of
        true -> empty;
        false -> {ok,array:get(I rem C, Arr)}
    end.

bottom({_,J,C,Arr} = T) ->
    case is_empty(T) of
        true -> empty;
        false -> {ok,array:get(J rem C, Arr)}
    end.

find(Fun, {I,J,C,Arr}) -> find(Fun, I, J, C, Arr).
find(_, I, J, _, _) when I =:= J -> not_found;
find(Fun, I, J, C, Arr) ->
    case Fun(array:get(I rem C, Arr)) of
        true ->
            {I,array:get(I rem C, Arr)};
        false ->
            find(Fun, I+1, J, C, Arr)
    end.

update(I, X, {_,_,C,Arr}=T) ->
    setelement(4, array:set(I rem C, X, Arr), T).

to_list({I,J,C,Arr}) -> to_list(I, J, C, Arr, []).
to_list(I, J, _, _, L) when I =:= J -> reverse(L);
to_list(I, J, C, Arr, L) ->
    to_list(I+1, J, C, Arr, [array:get(I rem C, Arr)|L]).

