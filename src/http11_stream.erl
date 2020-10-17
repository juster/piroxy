%% Generic HTTP11 binary message parser & stream generator.
%% Pass it a callback module that will decide what to do with
%% the HTTP 1.1 head and then the body (chunks).

-module(http11_stream).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([new/1, swap/2, read/2, encode/2]).

%%%
%%% INTERFACE EXPORTS
%%%

new([M,A]) ->
    case M:init(A) of
        {error,_} = Err ->
            Err;
        {ok,S} ->
            {ok, {head, pimsg:head_reader(), M, S}}
    end.

swap(State0, Fun) ->
    S = element(4,State0),
    setelement(4, State0, Fun(S)).

%% XXX: decided to use the empty atom instead of ?EMPTY
read(S, empty) ->
    {ok,S};

read({head,R0,M,S0}, Bin) ->
    case pimsg:head_reader(R0, Bin) of
        {error,_} = Err ->
            Err;
        {continue,R} ->
            {ok, {head,R,M,S0}};
        {done,StatusLn,Headers,Rest} ->
            case M:head(S0, StatusLn, Headers) of
                {ok,H,S} ->
                    R = pimsg:body_reader(H#head.bodylen),
                    read({body,R,M,S}, Rest);
                {error,_} = Err ->
                    Err
            end
    end;

read({body,R0,M,S0}, Bin0) ->
    case pimsg:body_reader(R0, Bin0) of
        {error,_}=Err ->
            Err;
        {continue,Bin,R} ->
            ok = M:body(S0, Bin),
            {ok, {body,R,M,S0}};
        {done,Bin,Rest} ->
            case Bin of
                empty -> ok;
                _ -> M:body(S0, Bin)
            end,
            case M:reset(S0) of
                shutdown ->
                    shutdown;
                {ok,S} ->
                    %% reset reader and recurse with updated state
                    R = pimsg:head_reader(),
                    read({head,R,M,S}, Rest)
            end
    end.

encode(_, #head{line=Line, headers=Headers}) ->
    [Line,<<?CRLF>>,fieldlist:to_binary(Headers)|<<?CRLF>>];

encode(_, {body,Body}) ->
    Body;

encode(_, {error,Reason}) ->
    [error_statusln(Reason)|<<?CRLF>>];

encode(_, {status,HttpStatus}) ->
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
            [<<?HTTP11>>," ",Bin|<<?CRLF>>]
    end.
