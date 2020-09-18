-module(phttp).

-export([centenc/1, formenc/1, compose_uri/1]).
-export([status_line/1, request_line/2]).
-export([head_reader/0, head_reader/2, body_reader/1, body_reader/2]).
-export([body_length/1, response_length/3]).
-export([method_bin/1]).

-import(lists, [reverse/1]).

-include("phttp.hrl").

%%% Split Subject into exactly N fields. Fields are separated by Pattern.
nsplit(N, _, _) when N < 1 ->
    error(bad_argument);
nsplit(N, Subject, Pattern) ->
    nsplit(N, Subject, Pattern, []).

nsplit(1, Subject, _, L) ->
    {ok, lists:reverse([Subject|L])};
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
    lists:flatten(lists:reverse(L2));
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
    lists:flatten(lists:join("&", L)).

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

concat(?EMPTY, Bin2) -> Bin2;
concat(Bin1, ?EMPTY) -> Bin1;
concat(Bin1, Bin2) -> <<Bin1/binary,Bin2/binary>>.

next_line(Bin1, ?EMPTY, _Max) ->
    {skip, Bin1};

next_line(Bin1, Bin2, Max) ->
    if
        byte_size(Bin1) + byte_size(Bin2) > Max ->
            {error, line_too_long};
        true ->
            next_line_(Bin1, Bin2)
    end.

next_line_(Bin1, Bin2) ->
    %%io:format("DBG next_line: ~p --- ~p~n", [Bin1, Bin2]),
    case binary:match(Bin2, <<?CRLF>>) of
        nomatch ->
            {skip, concat(Bin1, Bin2)};
        {0,_} ->
            {ok, Bin1, binary_part(Bin2, 2, byte_size(Bin2)-2)};
        {Pos,_} when byte_size(Bin2) == Pos+2 ->
            %% CRLF is at the end of Bin2
            Bin3 = concat(Bin1, Bin2),
            Line = binary_part(Bin3, 0, Pos),
            {ok, Line, ?EMPTY};
        {Pos,_} ->
            Bin3 = concat(Bin1, Bin2),
            Line = binary_part(Bin3, 0, Pos),
            Rest = binary_part(Bin3, Pos+2, byte_size(Bin3)-Pos-2),
            {ok, Line, Rest}
    end.

request_line(Bin1, Bin2) ->
    case next_line(Bin1, Bin2, ?REQUEST_MAX) of
        {skip,_} = T ->
            T;
        {error,_} = T ->
            T;
        {ok, ?EMPTY, _} ->
            {error,request_line_empty};
        {ok, Line, Rest} ->
            case nsplit(3, Line, ?SP) of
                {error,not_enough_fields} ->
                    {error, {bad_response_line, Line}};
                {error,Reason} ->
                    {error, Reason};
                {ok, [Method, Target, HttpVer]} ->
                    {ok, {{Method, Target, HttpVer}, Rest}}
            end
    end.

status_line(<<"HTTP/",VerMaj," ",Status:3/binary," ">>) ->
    {ok, {{VerMaj-$0, 0}, Status, ?EMPTY}};
status_line(<<"HTTP/",VerMaj," ",Status:3/binary," ",Phrase/binary>>) ->
    {ok, {{VerMaj-$0, 0}, Status, Phrase}};
status_line(<<"HTTP/",VerMaj,".",VerMin," ",Status:3/binary," ">>) ->
    %% Ignore a missing reason-phrase.
    {ok, {{VerMaj-$0, VerMin-$0}, Status, ?EMPTY}};
status_line(<<"HTTP/",VerMaj,".",VerMin," ",Status:3/binary," ", Phrase/binary>>) ->
    {ok, {{VerMaj-$0, VerMin-$0}, Status, Phrase}};
status_line(Line) ->
    {error, {bad_status_line,Line}}.

%% HTTP message reader.

track_header(N0, Bin) ->
    N = N0 + byte_size(Bin),
    if
        N > ?HEADER_MAX ->
            exit(header_too_big);
        true ->
            N
    end.

head_reader() -> {start,0,?EMPTY}.

head_reader({start,N,Bin1}, Bin2) ->
    case next_line(Bin1, Bin2, ?HEADLN_MAX) of
        {error,_} = T -> T;
        {skip,Bin3} ->
            {continue, {start, track_header(N, Bin3), Bin3}};
        {ok,Line,Bin3} ->
            head_reader({headers,0,Line,[],?EMPTY}, Bin3)
    end;

head_reader({headers,N0,StatusLine,Headers0,Bin1}, Bin2) ->
    case next_line(Bin1, Bin2, ?HEADLN_MAX) of
        {error,_} = T -> T;
        {skip,Bin3} ->
            N = track_header(N0, Bin3),
            {continue, {headers,N,StatusLine,Headers0,Bin3}};
        {ok,?EMPTY,Bin3} ->
            %% end of header lines
            {done,StatusLine,Headers0,Bin3};
            %%head_reader({endline,N0+2,StatusLine,Headers0,?EMPTY}, Bin3);
        {ok,Line,Bin3} ->
            case fieldlist:add(Line, Headers0) of
                {error,_} = Err -> Err;
                {ok,Headers} ->
                    N = track_header(N0, Line) + 2,
                    head_reader({headers,N,StatusLine,Headers,?EMPTY}, Bin3)
            end
    end;

head_reader({endline,N,StatusLine,Headers,Bin1}, Bin2) ->
    case next_line(Bin1, Bin2, ?HEADLN_MAX) of
        {error,_} = T -> T;
        {skip,Bin3} -> {continue,{endline,N,StatusLine,Headers,Bin3}};
        {ok,?EMPTY,Bin3} -> {done,StatusLine,Headers,Bin3};
        {ok,Line,_} -> {error,{expected_empty_line,Line}}
    end.

fixed({I,N}, Bin) when I >= N -> {done, Bin, ?EMPTY};
fixed({I0,N}, Bin) ->
    I = I0 + byte_size(Bin),
    if
        I < N ->
            {continue, Bin, {I,N}};
        I =:= N ->
            {done, Bin, ?EMPTY};
        I > N ->
            %% Returns the part within the boundary of length and
            %% the overflow (if any)
            Bin1 = binary_part(Bin, 0, N - I0),
            Bin2 = binary_part(Bin, byte_size(Bin), -1 * (I-N)),
            {done, Bin1, Bin2}
    end.

chunk(State, Bin) -> chunk(State, Bin, []).

%% Returns
%%  {error,Reason} in case of error
%%  {continue,Scanned,State}
%%  {done,Scanned,Rest}
%%
%% State
%%  {between,Keep}
%%    We are between chunks and are still scanning for end of line.
%%  {inside,I,N}
%%    We are inside a chunk and have not read the entire thing.
%%
chunk({between,Bin1}, Bin2, L) ->
    case chunk_size(Bin1, Bin2) of
        {error,_} = Err ->
            Err;
        {skip,Rest} ->
            {continue, reverse(L), {between,Rest}};
        {ok,0,_,Rest0} ->
            %% The last chunk should have size zero (0) and have an empty
            %% line immediately after the size line.
            case Rest0 of
                <<?CRLF>> ->
                    {done,reverse(L),?EMPTY};
                <<?CRLF,Rest/binary>> ->
                    {done,reverse(L),Rest};
                _ ->
                    {error,expected_crlf}
            end;
        {ok,Size,_,Rest} ->
            chunk({inside,0,Size}, Rest, L)
    end;

chunk({inside,I1,N}, Bin1, L) ->
    case fixed({I1,N}, Bin1) of
        {skip,I2} ->
            Bin2 = binary_part(Bin1, 0, I2),
            {continue, reverse([Bin2|L]), {inside,I1+I2,N}};
        {done,Bin2,Bin3} ->
            chunk(trailing_crlf, Bin3, [Bin2|L])
    end;

chunk(trailing_crlf, <<?CRLF>>, L) ->
    {continue, reverse(L), {between,?EMPTY}};

chunk(trailing_crlf, <<?CRLF,Bin1/binary>>, L) ->
    chunk({between,?EMPTY}, Bin1, L);

chunk(trailing_crlf, ?EMPTY, L) ->
    {continue, reverse(L), trailing_crlf};

chunk(trailing_crlf, Bin, _L) ->
    {error,{expected_crlf,Bin}}.

chunk_size(Bin1, Bin2) ->
    case next_line(Bin1, Bin2, ?CHUNKSZ_MAX) of
        {skip,_} = T -> T;
        {error,_} = T -> T;
        {ok,?EMPTY,_Rest} -> {error,chunk_size_empty};
        {ok,Line,Rest} ->
            Hex = case binary:match(Line, <<";">>) of
                      nomatch -> Line;
                      {Pos,_Len} -> binary_part(Line, 0, Pos)
                  end,
            case catch(binary_to_integer(Hex, 16)) of
                {'EXIT', {badarg, _}} ->
                    {error,{invalid_chunk_size,Hex}};
                {'EXIT', Reason} ->
                    {error,Reason}; % should not happen
                Size ->
                    {ok, Size, <<Line/binary,?CRLF>>, Rest}
            end
    end.

%% Pass the body_reader the result of body_length.
%% Returns the initial state of the reader.
body_reader(chunked) ->
    %%{chunked,{between,?EMPTY}};
    {chunked,trailing_crlf};
body_reader(ContentLength) when is_integer(ContentLength) ->
    {fixed,{0,ContentLength}}.

body_reader({chunked,State0}, Bin) ->
    case chunk(State0, Bin) of
        {continue,B,State} -> {continue,B,{chunked,State}};
        T -> T
    end;
body_reader({fixed,State0}, Bin) ->
    X = fixed(State0, Bin),
    case X of
        {continue,B,State} -> {continue,B,{fixed,State}};
        T -> T
    end.

body_length(Headers) ->
    %%io:format("DBG body_length_by_headers: Headers=~p~n", [Headers]),
    TransferEncoding = fieldlist:get_value(<<"transfer-encoding">>,
                                           Headers, ?EMPTY),
    ContentLength = fieldlist:get_value(<<"content-length">>,
                                        Headers, ?EMPTY),
    case {ContentLength, TransferEncoding} of
        {?EMPTY, ?EMPTY} ->
            {error, missing_length};
        {?EMPTY, Bin} ->
            %% XXX: not precise, potentially buggy/insecure. needs a rewrite.
            io:format("*DBG* transfer-encoding: ~s~n", [Bin]),
            case binary:match(Bin, <<"chunked">>) of
                nomatch ->
                    {error, missing_length};
                _ ->
                    {ok, chunked}
            end;
        {Bin, _} ->
            {ok, binary_to_integer(Bin)}
    end.

response_length(<<"HEAD">>, <<"200">>, _) -> {ok, 0};
response_length(_, <<"200">>, Headers) -> body_length(Headers);
response_length(_, <<"1",_,_>>, _) -> {ok, 0};
response_length(_, <<"204">>, _) -> {ok, 0};
response_length(_, <<"304">>, _) -> {ok, 0};
response_length(<<"HEAD">>, _, _) -> {ok, 0};
response_length(_ReqMethod, _ResStatus, ResHeaders) ->
    body_length(ResHeaders).

method_bin(get) -> <<"GET">>;
method_bin(post) -> <<"POST">>;
method_bin(head) -> <<"HEAD">>;
method_bin(put) -> <<"PUT">>;
method_bin(options) -> <<"OPTIONS">>;
method_bin(delete) -> <<"DELETE">>;
method_bin(patch) -> <<"PATCH">>;
method_bin(Method) -> exit({unknown_method, Method}).
