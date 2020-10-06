%%% phttp
%%%
%%% Generic utility functions related to HTTP.
%%%

-module(phttp).

-export([nsplit/3, centenc/1, formenc/1, compose_uri/1]).
-export([status_split/1, method_bin/1, method_atom/1, version_atom/1]).
-export([status_bin/1]).

-import(lists, [reverse/1, flatten/1]).
-include("../include/phttp.hrl").

%% Split Subject into exactly N fields. Fields are separated by Pattern.
nsplit(N, _, _) when N < 1 ->
    error(bad_argument);
nsplit(N, Subject, Pattern) ->
    nsplit(N, Subject, Pattern, []).

nsplit(1, Subject, _, L) ->
    {ok, reverse([Subject|L])};
nsplit(N, Subject, Pattern, L) ->
    case binary:split(Subject, Pattern) of
        [_] ->
            {error, not_enough_fields};
        [Bin1,Bin2] ->
            nsplit(N-1, Bin2, Pattern, [Bin1|L])
    end.

centenc(Chars) ->
    case unicode:characters_to_nfc_list(Chars) of
        {error,Err} -> error(Err);
        L -> centenc(L, [])
    end.

centenc([], L2) ->
    flatten(reverse(L2));
centenc([Ch|L1], L2) when Ch >= $a, Ch =< $z ->
    centenc(L1, [Ch|L2]);
centenc([Ch|L1], L2) when Ch >= $A, Ch =< $Z ->
    centenc(L1, [Ch|L2]);
centenc([Ch|L1], L2) when Ch >= $0, Ch =< $9 ->
    centenc(L1, [Ch|L2]);
centenc([Ch|L1], L2) when Ch =:= $-; Ch =:= $.; Ch =:= $_; Ch =:= $~ ->
    centenc(L1, [Ch|L2]);
centenc([Ch|L1], L2) ->
    %io:format("*DBG*: Ch=~.16B=~c~n", [Ch,Ch]),
    Enc = io_lib:format("%~2.16.0B", [Ch]),
    centenc(L1, [Enc|L2]).

formenc(Params) ->
    L = [[centenc(atom_to_list(K)),"=",centenc(V)] || {K,V} <- Params],
    flatten(lists:join("&", L)).

compose_uri({Scheme, UserInfo, Host, Port, Path, Query, Fragment}) ->
        L = [compose2(Scheme, UserInfo),
             compose3(Scheme, Host, Port),
             compose4(Path, Query, Fragment)],
        string:join(L, "").

compose2(Scheme, "") ->
        atom_to_list(Scheme) ++ "://";
compose2(Scheme, UserInfo) ->
        atom_to_list(Scheme) ++ "://" ++ UserInfo ++ "@".

compose3(http, Host, 80) ->
        Host;
compose3(https, Host, 443) ->
        Host;
compose3(_, Host, Port) ->
        Host ++ ":" ++ integer_to_list(Port).

compose4(Path, Query, Fragment) ->
        Path ++ Query ++ Fragment.

status_split(<<"HTTP/",VerMaj," ",Status:3/binary," ">>) ->
    {ok, {{VerMaj-$0, 0}, Status, ?EMPTY}};
status_split(<<"HTTP/",VerMaj," ",Status:3/binary," ",Phrase/binary>>) ->
    {ok, {{VerMaj-$0, 0}, Status, Phrase}};
status_split(<<"HTTP/",VerMaj,".",VerMin," ",Status:3/binary," ">>) ->
    %% Ignore a missing reason-phrase.
    {ok, {{VerMaj-$0, VerMin-$0}, Status, ?EMPTY}};
status_split(<<"HTTP/",VerMaj,".",VerMin," ",Status:3/binary," ", Phrase/binary>>) ->
    {ok, {{VerMaj-$0, VerMin-$0}, Status, Phrase}};
status_split(Line) ->
    {error, {bad_status_line,Line}}.

method_bin(get) -> <<"GET">>;
method_bin(post) -> <<"POST">>;
method_bin(head) -> <<"HEAD">>;
method_bin(put) -> <<"PUT">>;
method_bin(options) -> <<"OPTIONS">>;
method_bin(delete) -> <<"DELETE">>;
method_bin(patch) -> <<"PATCH">>;
method_bin(connect) -> <<"CONNECT">>;
method_bin(Method) -> exit({unknown_method, Method}).

method_atom(<<"GET">>) -> get;
method_atom(<<"POST">>) -> post;
method_atom(<<"HEAD">>) -> head;
method_atom(<<"PUT">>) -> put;
method_atom(<<"OPTIONS">>) -> options;
method_atom(<<"DELETE">>) -> delete;
method_atom(<<"PATCH">>) -> patch;
method_atom(<<"CONNECT">>) -> connect;
method_atom(_) -> unknown.

version_atom(<<?HTTP11>>) -> http11;
version_atom(<<"HTTP/1.0">>) -> http10;
version_atom(<<"HTTP/2.0">>) -> http20;
version_atom(_) -> unknown.

status_bin(http_ok) -> {ok,<<"200 OK">>};
status_bin(http_bad_request) -> {ok,<<"400 Bad Request">>};
status_bin(http_server_error) -> {ok,<<"500 Server Error">>};
status_bin(http_not_implemented) -> {ok,<<"501 Not Implemented">>};
status_bin(http_bad_gateway) -> {ok,<<"502 Bad Gateway">>};
status_bin(http_gateway_timeout) -> {ok,<<"504 Gateway Timeout">>};
status_bin(http_ver_not_supported) -> {ok,<<"505 HTTP Version Not Supported">>};
status_bin(_) -> not_found.