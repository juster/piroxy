%%% pimsg
%%% HTTP messages.
%%%
%%% Contains functions for simplistic HTTP message reading (splitting),
%%% calculating the body length, etc.

-module(pimsg).

-export([head_reader/0, head_reader/2, body_reader/1, body_reader/2]).
-export([body_length/1]).

-import(lists, [reverse/1]).
-include("../include/phttp.hrl").

%%%
%%% EXPORTS
%%%

track_header(N, ?EMPTY) ->
    N;

track_header(N0, M) ->
    N = N0 + M,
    if
        N > ?HEADER_MAX ->
            exit(head_too_big);
        true ->
            N
    end.

head_reader() -> {start,0,linebuf()}.

head_reader({start,N0,Buf0}, Bin0) ->
    case next_line(Buf0, Bin0, ?HEADLN_MAX) of
        {error,line_too_long} ->
            {error,http_uri_too_long};
        {skip,Buf} ->
            N = track_header(N0, buflen(Buf)),
            {continue, {start,N,Buf}};
        {ok,Line,Bin} ->
            head_reader({headers,0,Line,[],Buf0}, Bin)
    end;

head_reader({headers,N0,StatusLine,Headers0,Buf0}, Bin0) ->
    case next_line(Buf0, Bin0, ?HEADLN_MAX) of
        {error,_} = T -> T;
        {skip,Buf} ->
            N = track_header(N0, buflen(Buf)),
            {continue, {headers,N,StatusLine,Headers0,Buf}};
        {ok,?EMPTY,Rest} ->
            %% end of header lines
            {done,StatusLine,Headers0,Rest};
        {ok,Line,Bin} ->
            case fieldlist:add(Line, Headers0) of
                {error,_} = Err -> Err;
                {ok,Headers} ->
                    N = track_header(N0, byte_size(Line) + 2),
                    head_reader({headers,N,StatusLine,Headers,linebuf()}, Bin)
            end
    end.

fixed({I,N}, Bin) when I >= N -> {done, ?EMPTY, Bin};
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
chunk({between,_}=S, ?EMPTY, L) ->
    {continue, reverse(L), S};
chunk({between,Buf0}, Bin, L) ->
    case chunk_size(Buf0, Bin) of
        {error,_} = Err ->
            Err;
        {skip,Buf} ->
            {continue, reverse(L), {between,Buf}};
        {ok,0,Line,Rest} ->
            %% The last chunk should have size zero (0) and have an empty
            %% line immediately after the size line.
            chunk({end_crlf,?EMPTY}, Rest, [Line|L]);
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
            chunk({trailing_crlf,?EMPTY}, Bin3, [Bin2|L])
    end;

chunk({trailing_crlf,Bin1}, Bin2, L) ->
    case newline(Bin1, Bin2) of
        {continue,Bin3} ->
            {continue, reverse(L), {trailing_crlf,Bin3}};
        {done,Newline,Bin3} ->
            chunk({between,linebuf()}, Bin3, [Newline|L]);
        {error,_} = Err ->
            Err
    end;

chunk({end_crlf,Bin1}, Bin2, L) ->
    case newline(Bin1, Bin2) of
        {continue,Bin3} ->
            {continue, reverse(L), {end_crlf,Bin3}};
        {done,Newline,Bin3} ->
            {done, reverse([Newline|L]), Bin3};
        {error,_} = Err ->
            Err
    end.

newline(?EMPTY, ?EMPTY) ->
    {continue,?EMPTY};
newline(?EMPTY, <<?CRLF>>) ->
    {done,<<?CRLF>>,?EMPTY};
newline(?EMPTY, <<?CRLF,Bin2/binary>>) ->
    {done,<<?CRLF>>,Bin2};
newline(?EMPTY, (<<?CR>>)=Bin2) ->
    {continue,Bin2};
newline(<<?CR>>, <<?LF>>) ->
    {done,<<?CRLF>>,?EMPTY};
newline(<<?CR>>, <<?LF,Bin2/binary>>) ->
    {done,<<?CRLF>>,Bin2};
newline(Bin1, Bin2) ->
    io:format("*DBG* ~p~n", [[{bin1,Bin1},{bin2,Bin2}]]),
    {error,expected_crlf}.

chunk_size(Buf, Bin) ->
    case next_line(Buf, Bin, ?CHUNKSZ_MAX) of
        {skip,_} = T -> T;
        {error,_} = T -> T;
        {ok,?EMPTY,_Rest} -> {error,chunk_size_empty};
        {ok,Line,Rest} ->
            %%?DBG("chunk_size", {line,Line}),
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
    {chunked,{between,linebuf()}};

%% Used when content length is unknown and connection:close is specified.
%% The body never finishes and only stops when the socket is closed.
body_reader(until_closed) ->
    neverdone;

body_reader(ContentLength) when is_integer(ContentLength) ->
    {fixed,{0,ContentLength}}.

body_reader(neverdone, Bin) ->
    {continue,Bin,neverdone};

body_reader({chunked,State0}, Bin) ->
    case chunk(State0, Bin) of
        {continue,B,State} -> {continue,B,{chunked,State}};
        T ->
            %%io:format("*DBG* [chunked] ~p~n", [T]),
            T
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
            {error,{missing_length,Headers}};
        {?EMPTY, Bin} ->
            %% XXX: not precise, potentially buggy/insecure. needs a rewrite.
            %%io:format("*DBG* transfer-encoding: ~s~n", [Bin]),
            case binary:match(Bin, <<"chunked">>) of
                nomatch ->
                    {error,{missing_length,Headers}};
                _ ->
                    {ok, chunked}
            end;
        {Bin, _} ->
            {ok, binary_to_integer(Bin)}
    end.

%%%
%%% internal functions
%%%

concat(?EMPTY, Bin2) -> Bin2;
concat(Bin1, ?EMPTY) -> Bin1;
concat(Bin1, Bin2) -> <<Bin1/binary,Bin2/binary>>.

%% empty initial buffer for next_line
linebuf() -> {?EMPTY,?EMPTY}.

%% buffers are pairs of {AlreadyScanned, NeedToScan} binaries
buflen({?EMPTY,?EMPTY}) -> 0;
buflen({?EMPTY,Bin2}) -> byte_size(Bin2);
buflen({Bin1,?EMPTY}) -> byte_size(Bin1);
buflen({Bin1,Bin2}) -> byte_size(Bin1) + byte_size(Bin2).

bufpop({Bin1,_}) -> Bin1.

bufnext({_,Bin2}, Bin3) -> concat(Bin2, Bin3).

%% push done (scanned) binary into buffer or both done and todo binaries
bufpush({Bin1,_}, Bin3) -> {<<Bin1/binary,Bin3/binary>>, ?EMPTY}.
bufpush({Bin1,_}, Bin3, Bin4) -> {concat(Bin1, Bin3), Bin4}.

next_line(Buf, ?EMPTY, _Max) ->
    {skip, Buf};

next_line(Buf, Bin, Max) ->
    Len = buflen(Buf),
    if
        Len > Max ->
            {error,line_too_long};
        true ->
            next_line_(Buf, Bin)
    end.

next_line_(Buf, Bin1) ->
    %%io:format("DBG next_line: ~p --- ~p~n", [Bin1, Bin2]),
    Bin2 = bufnext(Buf, Bin1),
    case binary:match(Bin2, <<?CRLF>>) of
        nomatch ->
            case binary:last(Bin2) of
                ?CR ->
                    Pre = binary_part(Bin2, 0, byte_size(Bin2)-1),
                    {skip, bufpush(Buf, Pre, <<?CR>>)};
                _ ->
                    {skip, bufpush(Buf, Bin2)}
            end;
        {Pos,_} ->
            Pre = binary_part(Bin2, 0, Pos),
            Line = concat(bufpop(Buf), Pre),
            Rest = binary_part(Bin2, Pos+2, byte_size(Bin2)-Pos-2),
            {ok, Line, Rest}
    end.
