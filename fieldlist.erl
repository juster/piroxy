-module(fieldlist).

-include("pimsg.hrl").

-export([add/2, add_value/3, find/2, at/2, remove/2]).
-export([get_value/2, get_value/3]).
-export([to_proplist/1, to_iolist/1, to_binary/1, from_proplist/1]).

trimows(?EMPTY) ->
    ?EMPTY;
trimows(Bin) ->
    rtrimows(ltrimows(Bin)).

rtrimows(?EMPTY) ->
    ?EMPTY;
rtrimows(Bin) ->
    Last = binary:last(Bin),
    if
        Last =:= $\s orelse Last =:= $\t ->
            N = byte_size(Bin),
            if
                N =:= 1 ->
                    ?EMPTY;
                true ->
                    rtrimows(binary_part(Bin, 0, N-1))
            end;
        true ->
            Bin
    end.

ltrimows(?EMPTY) ->
    ?EMPTY;
ltrimows(Bin) ->
    First = binary:first(Bin),
    if
        First =:= $\s orelse First =:= $\t ->
            N = byte_size(Bin),
            if
                N =:= 1 ->
                    ?EMPTY;
                true ->
                    ltrimows(binary_part(Bin, 1, N-1))
            end;
        true ->
            Bin
    end.

add(F, FL) ->
    case binary:match(F, <<?COLON>>) of
        nomatch ->
            {error, colon_missing};
        {Pos,_} ->
            {ok, [{Pos,F}|FL]}
    end.

add_value(Name, Value, FL) ->
    BinName = list_to_binary(Name),
    BinValue = list_to_binary(Value),
    [{length(Name),<<BinName/binary,?COLON,BinValue/binary>>}|FL].

find(Name, FL) ->
    find(Name, FL, 1).

find(_, [], _) ->
    not_found;

find(Name1, [{Len,F}|FL], I) ->
    case binary_lcase(binary_part(F, 0, Len)) of
        Name1 -> I;
        _ -> find(Name1, FL, I+1)
    end.

at(I, FL) ->
    {I,F} = lists:nth(I, FL),
    binary_part(F, I+1, byte_size(F)-I-1).

remove(I, FL) ->
    lists:sublist(FL, 1, I-1) ++ lists:nthtail(I, FL).

get_value(Field, FL) -> get_value(Field, FL, not_found).

get_value(_Field, [], Default) ->
    Default;

get_value(Field, [{Len,Line}|FL], Default) ->
    case binary_lcase(binary_part(Line, 0, Len)) of
        Field when byte_size(Line) =< Len-1 ->
            ?EMPTY;
        Field ->
            Value0 = binary_part(Line, Len+1, byte_size(Line) - Len - 1),
            trimows(binary_lcase(Value0));
        _ ->
            get_value(Field, FL, Default)
    end.

to_iolist([]) ->
    <<>>;

to_iolist(FL) ->
    L = [<<?CRLF>>|lists:join(<<?CRLF>>, [Line || {_I, Line} <- FL])],
    lists:reverse(L).

to_binary(FL) ->
    iolist_to_binary(to_iolist(FL)).

to_proplist(FL) ->
    to_proplist(FL, []).

to_proplist([], PL) ->
    PL;

to_proplist([{Pos,Bin}|FL], PL) ->
    Prop = binary_to_list(binary_lcase(binary_part(Bin, 0, Pos))),
    Value = binary_to_list(trimows(binary_part(Bin, Pos+1, byte_size(Bin)-Pos-1))),
    to_proplist(FL, [{list_to_atom(Prop),Value}|PL]).

from_proplist(PL) ->
    lists:foldl(fun ({K,V}, FL) ->
                        fieldlist:add_value(K, V, FL)
                end, [], PL).

binary_lcase(?EMPTY) ->
    ?EMPTY;

binary_lcase(Bin) ->
    binary_lcase(Bin, <<>>).

binary_lcase(<<>>, Bin) ->
    Bin;

binary_lcase(<<Byte,Bin0/binary>>, Bin) ->
    if
        Byte > 16#40 andalso Byte < 16#5B ->
            XByte = Byte bxor 16#20,
            binary_lcase(Bin0, <<Bin/binary, XByte>>);
        true ->
            binary_lcase(Bin0, <<Bin/binary, Byte>>)
    end.

