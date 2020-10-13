%%% pimsg
%%% HTTP messages.
%%%
%%% Contains functions for simplistic HTTP message reading (splitting),
%%% calculating the body length, etc.

-module(pimsg).

-export([head_reader/0, head_reader/2, body_reader/1, body_reader/2]).
-export([body_length/1, request_length/2, response_code/1, response_length/3]).

-import(lists, [reverse/1]).
-include("../include/phttp.hrl").

%%%
%%% exports
%%%

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
fixed(S, ?EMPTY) -> {continue, ?EMPTY, S};
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
        {ok,0,Line,Rest} ->
            %% The last chunk should have size zero (0) and have an empty
            %% line immediately after the size line.
            chunk(end_crlf, Rest, [Line|L]);
        {ok,Size,Line,Rest} ->
            chunk({inside,0,Size}, Rest, [Line|L])
    end;

chunk({inside,_,_}=S, ?EMPTY, L) ->
    {continue, reverse(L), S};
chunk({inside,I1,N}, Bin1, L) ->
    case fixed({I1,N}, Bin1) of
        {continue,Bin2,{I2,N}} ->
            {continue, reverse([Bin2|L]), {inside,I2,N}};
        {done,Bin2,Bin3} ->
            chunk(trailing_crlf, Bin3, [Bin2|L])
    end;

chunk(trailing_crlf, <<?CRLF>>, L) ->
    {continue, reverse([<<?CRLF>>|L]), {between,?EMPTY}};
chunk(trailing_crlf, <<?CRLF,Bin1/binary>>, L) ->
    chunk({between,?EMPTY}, Bin1, [<<?CRLF>>|L]);
chunk(trailing_crlf, ?EMPTY, L) ->
    {continue, reverse(L), trailing_crlf};
chunk(trailing_crlf, Bin, _L) ->
    {error,{expected_crlf,Bin}};

chunk(end_crlf, <<?CRLF>>, L) ->
    {done,reverse([<<?CRLF>>|L]),?EMPTY};
chunk(end_crlf, <<?CRLF,Rest/binary>>, L) ->
    {done,reverse([<<?CRLF>>|L]),Rest};
chunk(end_crlf, ?EMPTY, L) ->
    {continue, reverse(L), end_crlf};
chunk(end_crlf, _, _L) ->
    {error,expected_crlf}.

chunk_size(Bin1, Bin2) ->
    case next_line(Bin1, Bin2, ?CHUNKSZ_MAX) of
        {skip,_} = T -> T;
        {error,_} = T -> T;
        {ok,?EMPTY,_Rest} -> {error,chunk_size_empty};
        {ok,Line,Rest} ->
            ?DBG("chunk_size", {line,Line}),
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
    {chunked,{between,?EMPTY}};
    %%{chunked,trailing_crlf};

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
            %%io:format("*DBG* transfer-encoding: ~s~n", [Bin]),
            case binary:match(Bin, <<"chunked">>) of
                nomatch ->
                    {error, missing_length};
                _ ->
                    {ok, chunked}
            end;
        {Bin, _} ->
            {ok, binary_to_integer(Bin)}
    end.

response_code(StatusLn) ->
    {ok,[_,Status,_]} = phttp:nsplit(3, StatusLn, <<" ">>),
    Status.

response_length_(head, <<"200">>, _) -> {ok, 0};
response_length_(_, <<"200">>, Headers) -> body_length(Headers);
response_length_(_, <<"1",_,_>>, _) -> {ok, 0};
response_length_(_, <<"204">>, _) -> {ok, 0};
response_length_(_, <<"304">>, _) -> {ok, 0};
response_length_(head, _, _) -> {ok, 0};
response_length_(_, _, ResHeaders) -> body_length(ResHeaders).

response_length(Method, Line, Headers) ->
    response_length_(Method, response_code(Line), Headers).

request_length(connect, _) -> {ok,0};
request_length(get, _) -> {ok,0};
request_length(options, _) -> {ok,0};
request_length(_, Headers) -> body_length(Headers).

%%%
%%% internal functions
%%%

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
            Bin3 = binary_part(Bin2, 0, Pos),
            Line = concat(Bin1, Bin3),
            {ok, Line, ?EMPTY};
        {Pos,_} ->
            Bin3 = binary_part(Bin2, 0, Pos),
            Line = concat(Bin1, Bin3),
            Rest = binary_part(Bin2, Pos+2, byte_size(Bin2)-Pos-2),
            {ok, Line, Rest}
    end.

%% request_line(Bin1, Bin2) ->
%%     case next_line(Bin1, Bin2, ?REQUEST_MAX) of
%%         {skip,_} = T ->
%%             T;
%%         {error,_} = T ->
%%             T;
%%         {ok, ?EMPTY, _} ->
%%             {error,request_line_empty};
%%         {ok, Line, Rest} ->
%%             case phttp:nsplit(3, Line, ?SP) of
%%                 {error,not_enough_fields} ->
%%                     {error, {bad_response_line, Line}};
%%                 {error,Reason} ->
%%                     {error, Reason};
%%                 {ok, [Method, Target, HttpVer]} ->
%%                     {ok, {{Method, Target, HttpVer}, Rest}}
%%             end
%%     end.
