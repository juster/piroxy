%% Generic HTTP11 binary message parser & stream generator.
%% Pass it a callback module that will decide what to do with
%% the HTTP 1.1 head and then the body (chunks).

-module(http11_stream).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([new/2, read/2, fail/2, encode/1]).

%%%
%%% INTERFACE EXPORTS
%%%

new(M, A) ->
    case M:init(A) of
        {error,_} = Err ->
            Err;
        {ok,S} ->
            {ok, {head, pimsg:head_reader(), M, S}}
    end.

%% XXX: decided to use the empty atom instead of ?EMPTY
read(S, empty) ->
    {ok,S};

read({head,R0,M,S}, Bin) ->
    case pimsg:head_reader(R0, Bin) of
        {error,Rsn} ->
            {error, M:fail(S, Rsn)};
        {continue,R} ->
            {ok, {head,R,M,S}};
        {done,StatusLn,Headers,Rest} ->
            case M:head(S, StatusLn, Headers) of
                {ok,H} ->
                    R = pimsg:body_reader(H#head.bodylen),
                    read({body,R,M,S}, Rest);
                {error,Rsn} ->
                    {error, M:fail(S, Rsn)};
                Any ->
                    Any
            end
    end;

read({body,R0,M,S0}, Bin0) ->
    case pimsg:body_reader(R0, Bin0) of
        {error,Rsn} ->
            {error, M:fail(S0, Rsn)};
        {continue,Bin,R} ->
            M:body(S0, Bin),
            {ok, {body,R,M,S0}};
        {done,Bin,Rest} ->
            case Bin of
                empty -> ok;
                _ -> M:body(S0, Bin)
            end,
            S = M:reset(S0),
            R = pimsg:head_reader(),
            read({head,R,M,S}, Rest)
    end.

fail({_,_,M,S}, Reason) ->
    M:fail(S, Reason).

encode(#head{line=Line, headers=Headers}) ->
    [Line,<<?CRLF>>,fieldlist:to_binary(Headers)|<<?CRLF>>];

encode({body,Body}) ->
    Body;

encode({error,Reason}) ->
    [error_statusln(Reason)|<<?CRLF>>];

encode({status,HttpStatus}) ->
    case phttp:status_bin(HttpStatus) of
        {ok,Bin} ->
            [<<?HTTP11>>," ",Bin,<<?CRLF>>|<<?CRLF>>];
        not_found ->
            exit(badarg)
    end.

%%%
%%% INTERNAL FUNCTIONS
%%%

%% handle all errors created when attempting to parse the request
error_statusln(host_mismatch) -> error_statusln(http_bad_request);
error_statusln(host_missing) -> error_statusln(http_bad_request);
error_statusln({malformed_uri,_,_}) -> error_statusln(http_bad_request);
error_statusln({unknown_method,_}) -> error_statusln(http_bad_request);
error_statusln({unknown_version,_}) -> error_statusln(http_bad_request);
error_statusln({unknown_length,_,_}) -> error_statusln(http_bad_request);

%% from pimsg:body_length/1
error_statusln({missing_length,_}) -> error_statusln(http_bad_request);

error_statusln(Reason) ->
    case phttp:status_bin(Reason) of
        {ok,Bin} -> Bin;
        not_found ->
            {ok,Bin} = phttp:status_bin(http_server_error),
            [Bin|<<?CRLF>>]
    end.
