%%% pihttp_lib
%%%
%%% Generic utility functions related to HTTP binaries.
%%%

-module(pihttp_lib).

-export([nsplit/3, centenc/1, formenc/1, compose_uri/1]).
-export([status_split/1, method_bin/1, method_atom/1, version_atom/1]).
-export([status_bin/1, encode/1]).
-export([trace/4]).

%%% HTTP message parsing functions.
-export([head_reader/0, head_reader/2, body_reader/1, body_reader/2]).
-export([body_length/1]).

-import(lists, [reverse/1, flatten/1]).
-include("../include/pihttp_lib.hrl").

%%% Split Subject into exactly N fields. Fields are separated by Pattern.
nsplit(N, _, _) when N < 1 ->
    error(badarg);
nsplit(N, Subject, Pattern) ->
    nsplit(N, Subject, Pattern, []).
nsplit(1, Subject, _, L) ->
    {ok, reverse([Subject|L])};
nsplit(N, Subject, Pattern, L) ->
    case binary:split(Subject, Pattern) of
        [_] ->
            {error,badarg};
        [Bin1,Bin2] ->
            nsplit(N-1, Bin2, Pattern, [Bin1|L])
    end.

centenc(Chars) ->
    case unicode:characters_to_nfc_list(Chars) of
        {error,Err} -> error(Err);
        L -> centenc(L, [])
    end.
centenc([], L2) ->
    reverse(L2);
centenc([Ch|L1], L2)
  when Ch >= $a, Ch =< $z;
       Ch >= $A, Ch =< $Z;
       Ch >= $0, Ch =< $9;
       Ch =:= $-; Ch =:= $.; Ch =:= $_; Ch =:= $~ ->
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
    {error, {badarg,Line}}.

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

status_bin(http_ok) -> <<"200 OK">>;
status_bin(http_bad_request) -> <<"400 Bad Request">>;
status_bin(http_not_found) -> <<"404 Not Found">>;
status_bin(http_uri_too_long) -> <<"414 URI Too Long">>;
status_bin(http_server_error) -> <<"500 Server Error">>;
status_bin(http_not_implemented) -> <<"501 Not Implemented">>;
status_bin(http_bad_gateway) -> <<"502 Bad Gateway">>;
status_bin(http_gateway_timeout) -> <<"504 Gateway Timeout">>;
status_bin(http_ver_not_supported) -> <<"505 HTTP Version Not Supported">>;
status_bin(_) -> not_found.

encode(#head{line=Line, headers=Headers}) ->
    [Line,<<?CRLF>>,fieldlist:to_binary(Headers)|<<?CRLF>>];
encode({body,Body}) ->
    Body;
encode({error,Reason}) ->
    Bin = error_bin(Reason),
    [<<?HTTP11," ">>,Bin,<<?CRLF>>,<<"content-length:0">>,<<?CRLF>>,<<?CRLF>>];
encode({status,HttpStatus}) ->
    case status_bin(HttpStatus) of
        not_found ->
            exit(badarg);
        Bin ->
            [<<?HTTP11," ">>,Bin,<<?CRLF>>,<<"content-length:0">>,<<?CRLF>>,<<?CRLF>>]
    end.

error_bin(host_mismatch) -> status_bin(http_bad_request);
error_bin(host_missing) -> status_bin(http_bad_request);
error_bin({malformed_uri,_,_}) -> status_bin(http_bad_request);
error_bin({unknown_method,_}) -> status_bin(http_bad_request);
error_bin({unknown_version,_}) -> status_bin(http_bad_request);
error_bin({unknown_length,_,_}) -> status_bin(http_bad_request);
error_bin({missing_length,_}) -> status_bin(http_bad_request);
error_bin({shutdown,timeout}) -> status_bin(http_gateway_timeout); % http11_res
error_bin({missing_length,_,_}) -> status_bin(http_bad_gateway); % http11_res:body_length/3
error_bin(_) -> status_bin(http_bad_gateway).

trace(_, _, _, _) ->
    ok;
trace(Sess, Host, Arrow, Term) ->
    {_,{_H,M,S}} = calendar:local_time(),
    Str = case Term of
              #head{} ->
                  Line = iolist_to_binary(Term#head.line),
                  if
                      byte_size(Line) > 60 ->
                          Bin = binary_part(Line, 0, 60),
                          <<Bin/binary,"...">>;
                      true ->
                          Line
                  end;
              _ ->
                  Term
          end,
    io:format("~2..0B~2..0B ~p [~B] ~s (~s) ~s~n",
              [M,S,self(),Sess,Arrow,Host,Str]).

%%%
%%% HTTP message binary parsing.
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
    Chunked = fieldlist:has_value(<<"transfer-encoding">>,
                                  <<"chunked">>,
                                  Headers),
    ContentLength = fieldlist:get_value(<<"content-length">>,
                                        Headers, ?EMPTY),
    case {ContentLength, Chunked} of
        {?EMPTY, false} ->
            {error,{missing_length,Headers}};
        {?EMPTY, true} ->
            {ok, chunked};
        {_Bin, true} ->
            %% if both are present, chunked takes precedence
            {ok, chunked};
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
