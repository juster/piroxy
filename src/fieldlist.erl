-module(fieldlist).

-include("../include/pihttp_lib.hrl").
-import(lists, [reverse/1, reverse/2]).

-export([add/2, add_value/3, find/2, at/2, remove/2]).
-export([get_value/2, get_value/3, get_value_split/2, has_value/3]).
-export([get_lcase/2, to_proplist/1, to_iolist/1, to_binary/1]).
-export([from_proplist/1, trimows/1, binary_lcase/1]).

trimows(?EMPTY) ->
    ?EMPTY;

trimows(Bin) ->
    string:trim(Bin, both, "\s\t").

add(F, FL) ->
    case binary:match(F, <<?COLON>>) of
        nomatch ->
            {error,{colon_missing,F}};
        {Pos,_} ->
            {ok, [{Pos,F}|FL]}
    end.

add_value(Name,Value,FL) when is_atom(Name) ->
    add_value(atom_to_list(Name),Value,FL);

add_value(Name,Value,FL) when is_list(Name) ->
    add_value(list_to_binary(Name),Value,FL);

add_value(Name,Value,FL) when is_list(Value) ->
    add_value(Name,list_to_binary(Value),FL);

add_value(Name,Value,FL) when is_binary(Name); is_binary(Value) ->
    [{size(Name),<<Name/binary,": ",Value/binary>>}|FL];

add_value(_,_,_) ->
    exit(badarg).

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


remove(Name, FL1) ->
    remove(binary_lcase(Name), FL1, []).

remove(_Name, [], FL2) ->
    reverse(FL2);

remove(Name, [{Len,F}=T|FL1], FL2) ->
    case binary_lcase(binary_part(F, 0, Len)) of
        Name ->
            reverse(FL2, FL1);
        _ ->
            remove(Name, FL1, [T|FL2])
    end.

get_value(Field, FL) -> get_value(Field, FL, not_found).

get_value(_Field, [], Default) ->
    Default;

get_value(Field, [{Len,Line}|FL], Default) ->
    case binary_lcase(binary_part(Line, 0, Len)) of
        Field when byte_size(Line) =< Len+1 ->
            ?EMPTY;
        Field ->
            Value0 = binary_part(Line, Len+1, byte_size(Line) - Len - 1),
            trimows(Value0);
        _ ->
            get_value(Field, FL, Default)
    end.

get_lcase(Field, FL) ->
    case get_value(Field, FL) of
        not_found ->
            not_found;
        Bin ->
            binary_lcase(Bin)
    end.

has_value(Field, Val1, FL) ->
    case get_value(Field, FL) of
        not_found ->
            false;
        Val2 ->
            L = [trimows(Bin) || Bin <- binary:split(Val2, <<",">>, [global,trim_all])],
            lists:any(fun (V) when V =:= Val1 -> true; (_) -> false end,
                      [binary_lcase(Bin) || Bin <- L])
    end.

get_value_split(Field, FL) ->
    case get_value(Field, FL) of
        not_found ->
            not_found;
        V ->
            [trimows(Bin) || Bin <- binary:split(V, <<";">>, [global,trim_all])]
    end.

to_iolist([]) ->
    <<>>;

to_iolist(FL) ->
    L = [<<?CRLF>>|lists:join(<<?CRLF>>, [Line || {_I, Line} <- FL])],
    lists:reverse(L).

to_binary(FL) ->
    iolist_to_binary(to_iolist(FL)).

to_proplist(FL) ->
    lists:map(fun ({Pos,Bin}) ->
                      PropBin = binary_part(Bin, 0, Pos),
                      ValueBin = binary_part(Bin, Pos+1, byte_size(Bin)-Pos-1),
                      Prop = list_to_atom(binary_to_list(binary_lcase(PropBin))),
                      Value = binary_to_list(trimows(ValueBin)),
                      {Prop,Value}
              end, FL).

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

