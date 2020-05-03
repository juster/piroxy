-module(phttp).

-export([status_line/2, request_line/2]).
-export([header_line/2]).
-export([response_head/0, response_head/3]).
-export([body_length/3, body_reader/1, body_next/3]).

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

next_line(Bin1, ?EMPTY, _Max) ->
    {skip, Bin1};

next_line(Bin1, Bin2, Max) ->
    %%io:format("DBG next_line: ~p --- ~p~n", [Bin1, Bin2]),
    Bin3 = case Bin1 of
               ?EMPTY ->
                   Bin2;
               _ ->
                   <<Bin1/binary,Bin2/binary>>
           end,
    N = min(Max,byte_size(Bin3)),
    case binary:match(Bin3, <<?CRLF>>, [{scope,{0,N}}]) of
        nomatch when byte_size(Bin3) >= Max ->
            {error, line_too_long};
        nomatch ->
            {skip, Bin3};
        {0,_} when byte_size(Bin3) =:= 2 ->
            {ok, ?EMPTY, ?EMPTY};
        {0,_} ->
            {ok, ?EMPTY, binary_part(Bin3, 2, byte_size(Bin3)-2)};
        {Pos,_} when byte_size(Bin3) =:= Pos+2 ->
            Line = binary_part(Bin3, 0, Pos),
            {ok, Line, ?EMPTY};
        {Pos,_} ->
            Line = binary_part(Bin3, 0, Pos),
            Rest = binary_part(Bin3, Pos+2, byte_size(Bin3)-Pos-2),
            {ok, Line, Rest}
    end.

request_line(Bin1, Bin2) ->
    case next_line(Bin1, Bin2, ?REQUEST_MAX) of
        {skip,_} = Skip ->
            Skip;
        {error,_} = Error ->
            Error;
        {ok, ?EMPTY, _} ->
            {error,request_line_empty};
        {ok, Line, Rest} ->
            case nsplit(3, Line, ?SP) of
                {error,not_enough_fields} ->
                    {error, {bad_response_line, Line}};
                {ok, [Method, Target, HttpVer]} ->
                    {ok, {{Method, Target, HttpVer}, Rest}}
            end
    end.

status_line(Bin1, Bin2) ->
    %%io:format("DBG: status_line: ~p --- ~p~n", [Bin1, Bin2]),
    case next_line(Bin1, Bin2, ?STATUS_MAX) of
        Skip = {skip,_} ->
            Skip;
        Error = {error,_} ->
            Error;
        {ok, ?EMPTY, _} ->
            {error,status_line_empty};
        {ok, Line, Rest} ->
            case Line of
                <<"HTTP/",VerMaj," ",Status:3/binary," ">> ->
                    {ok, {{{VerMaj-$0, 0}, Status, ?EMPTY}, Rest}};
                <<"HTTP/",VerMaj," ",Status:3/binary," ",Phrase/binary>> ->
                    {ok, {{{VerMaj-$0, 0}, Status, Phrase}, Rest}};
                <<"HTTP/",VerMaj,".",VerMin," ",Status:3/binary," ">> ->
                    %% Ignore a missing reason-phrase.
                    {ok, {{{VerMaj-$0, VerMin-$0}, Status, ?EMPTY}, Rest}};
                <<"HTTP/",VerMaj,".",VerMin," ",Status:3/binary," ",Phrase/binary>> ->
                    {ok, {{{VerMaj-$0, VerMin-$0}, Status, Phrase}, Rest}};
                _ ->
                    {error, {bad_status_line, Line}}
            end
    end.

header_line(Bin1, Bin2) ->
    next_line(Bin1, Bin2, ?HEADER_MAX).

%%collect_headers(Headers, Buff, ?EMPTY) ->
%%    {skip, Buff, Headers};

collect_headers(Headers0, Buff, Next) ->
    case header_line(Buff, Next) of
        {skip, Bin} ->
            {skip, Bin, Headers0};
        {error,_} = Error ->
            Error;
        {ok, ?EMPTY, Rest} ->
            {ok, Rest, Headers0};
        {ok, Header, Rest} ->
            %%io:format("DBG adding field: ~p~n", [Header]),
            case fieldlist:add(Header, Headers0) of
                {ok, Headers} ->
                    collect_headers(Headers, ?EMPTY, Rest);
                {error, Reason} ->
                    {error, {Reason, Header}}
            end
    end.

response_head() ->
    #headstate{state = http_status}.

response_head(Bin1, Bin2, RespState = #headstate{state=http_status}) ->
    case phttp:status_line(Bin1, Bin2) of
        {error,_} = Error ->
            Error;
        {skip, Buff} ->
            {skip, Buff, RespState};
        {ok, {Status, Rest}} ->
            %%{status, Status, Rest, RespState#headstate{state=http_headers}}
            {redo, Rest, RespState#headstate{state=http_headers, status=Status}}
    end;

response_head(Bin1, Bin2, RespState = #headstate{state=http_headers}) ->
    Headers0 = RespState#headstate.headers,
    case collect_headers(Headers0, Bin1, Bin2) of
        {error, Reason} ->
            {error, Reason};
        {skip, Buff} ->
            {skip, Buff, RespState};
        {redo, Rest, Headers} ->
            {redo, Rest, RespState#headstate{headers=Headers}};
        {ok, Rest, Headers} ->
            {last, Rest, RespState#headstate.status, Headers}
    end.

body_reader(chunked) ->
    #bodystate{state=between_chunks, nread=0, length=unused};

body_reader(ContentLength) ->
    #bodystate{state=dumb, nread=0, length=ContentLength}.

%% Works like a lexer, works at reading the entire body. Returns
%% Returns one of:
%%   {skip, Buffer, State}
%%     ... when we need more input to read more of the body
%%   {wait, Done, State}
%%     ... when we need more input, but we don't need to buffer anything
%%   {redo, Done, Buffer, Rest, State}
%%     ... when the caller should call again with Buffer, Rest, and State
%%         (Done is a chunk of Body data that has passed through the lexing)
%%   {last, Done, Rest}
%%     ... when the last chunk of body data is Done and Rest is any extra
%%
body_next(_IgnBuff, Bin, State = #bodystate{state=dumb, nread=NRead0, length=Length}) ->
    NRead = byte_size(Bin) + NRead0,
    if
        NRead < Length ->
            {wait, Bin, ?EMPTY, State#bodystate{nread=NRead}};
        NRead =:= Length ->
            {last, Bin, ?EMPTY};
        NRead > Length ->
            Bin1 = binary_part(Bin, 0, Length - NRead0),
            Bin2 = binary_part(Bin, byte_size(Bin), -1 * (NRead-Length)),
            {last, Bin1, Bin2}
    end;

body_next(Bin1, Bin2, State = #bodystate{state=between_chunks}) ->
    case chunk_size(Bin1, Bin2) of
        {error,_} = Error ->
            Error;
        {skip, Rest} ->
            {wait, ?EMPTY, Rest, State};
        {ok, {0, Line, Rest0}} ->
            %% The last chunk should have size zero (0) and have an empty
            %% line immediately after the size line.
            case Rest0 of
                <<?CRLF,Rest/binary>> ->
                    {last, <<Line/binary,?CRLF>>, Rest};
                _ ->
                    {error, lastchunk_not_emptyline}
            end;
        {ok, {Size, Line, Rest}} ->
            NewState = State#bodystate{state=inside_chunk, nread=0, length=Size},
            {redo, <<Line/binary,?CRLF>>, ?EMPTY, Rest, NewState}
    end;

body_next(_, Bin, State = #bodystate{state=inside_chunk, nread=NRead0, length=Length}) ->
    NRead = NRead0 + byte_size(Bin),
    if
        NRead < Length ->
            {redo, Bin, ?EMPTY, ?EMPTY, State#bodystate{state=inside_chunk, nread=NRead}};
        NRead =:= Length ->
            {redo, Bin, ?EMPTY, ?EMPTY, State#bodystate{state=between_chunks,
                                                        nread=0, length=unused}};
        NRead > Length ->
            Bin1 = binary_part(Bin, 0, Length - NRead0),
            Bin2 = binary_part(Bin, byte_size(Bin), -1 * (NRead-Length)),
            NextState = State#bodystate{state=between_chunks,
                                        nread=0, length=null},
            {redo, Bin1, ?EMPTY, Bin2, NextState}
    end.

chunk_size(Bin1, Bin2) ->
    case next_line(Bin1, Bin2, ?CHUNKSZ_MAX) of
        {skip,_} = Skip ->
            Skip;
        {error,_} = Error ->
            Error;
        {ok, ?EMPTY, _Rest} ->
            {error, chunk_size_empty};
        {ok, Line, Rest} ->
            Hex = case binary:match(Line, <<";">>) of
                      nomatch ->
                          Line;
                      {Pos,_Len} ->
                          binary_part(Line, 0, Pos)
                  end,
            case catch(binary_to_integer(Hex, 16)) of
                {'EXIT', {badarg, _}} ->
                    {error, {invalid_chunk_size, Hex}};
                {'EXIT', Reason} ->
                    {error, Reason}; % should not happen
                Size ->
                    {ok, {Size, <<Line/binary,?CRLF>>, Rest}}
            end
    end.

body_length_by_headers(Headers) ->
    %%io:format("DBG body_length_by_headers: Headers=~p~n", [Headers]),
    TransferCoding = case fieldlist:get_value(<<"transfer-encoding">>, Headers) of
                         ?EMPTY -> not_found; X -> X
                     end,
    ContentLength = case fieldlist:get_value(<<"content-length">>, Headers) of
                        ?EMPTY -> not_found; Y -> Y
                    end,
    case {ContentLength, TransferCoding} of
        {not_found, not_found} ->
            {error, missing_length};
        {not_found, Bin} ->
            %% XXX: not precise, potentially buggy/insecure. needs a rewrite.
            case binary:match(Bin, <<"chunked">>) of
                nomatch ->
                    {ok, chunked};
                _ ->
                    {error, missing_length}
            end;
        {Bin, _} ->
            {ok, binary_to_integer(Bin)}
    end.

body_length(<<"HEAD">>, <<"200">>, _) ->
    {ok, 0};

body_length(_, <<"200">>, Headers) ->
    body_length_by_headers(Headers);

body_length(_, <<"1",_,_>>, _) ->
    {ok, 0};

body_length(_, <<"204">>, _) ->
    {ok, 0};

body_length(_, <<"304">>, _) ->
    {ok, 0};

body_length(<<"HEAD">>, _, _) ->
    {ok, 0};

body_length(_ReqMethod, _RespStatus, RespHeaders) ->
    body_length_by_headers(RespHeaders).

