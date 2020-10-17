-module(piqueue).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([new/1, expect/2, append/3, finish/2]).

%%%
%%% EXTERNAL FUNCTIONS
%%%

new(Fun) ->
    {[],dict:new(),Fun}.

expect(Key, {Q,D,F}) ->
    {Q ++ [{Key,wait}], dict:store(Key, [], D), F}.

append(Key, Resp, {Q,D,F}) ->
    {Q, dict:append(Key, Resp, D), F}.

finish(Key, {Q0,D,F}) ->
    case Q0 of
        [{Key,_}|Q] ->
            L = dict:fetch(Key, D),
            F(L),
            flush(Q, dict:erase(Key, D), F);
        _ ->
            case lists:keyfind(Key, 1, Q0) of
                false ->
                    ?LOG_ERROR("key (~p) not found, finish called >1 times?",
                               [Key]),
                    {Q0,D,F};
                {Key,done} ->
                    {Q0,D,F};
                {Key,wait} ->
                    Q = lists:keyreplace(Key, 1, Q0, {Key,done}),
                    {Q,D,F}
            end
    end.

%%%
%%% INTERNAL FUNCTIONS
%%%

flush([{Key,done}|Q], D0, F) ->
    {L,D} = dict:take(Key, D0),
    F(L),
    flush(Q, D, F);

flush(Q, D, F) ->
    {Q,D,F}.
