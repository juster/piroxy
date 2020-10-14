%% Generic HTTP11 binary message parser & stream generator.
%% Pass it a callback module that will decide what to do with
%% the HTTP 1.1 head and then the body (chunks).

-module(http11_stream).

-export([new/2, read/2]).

new(M, A) ->
    case M:init(A) of
        {error,_} = Err ->
            Err;
        {ok,S} ->
            {head, pimsg:head_reader(), M, S}
    end.

%% XXX: decided to use the empty atom instead of ?EMPTY
read(empty, S) ->
    S;

read(Bin, {head,R0,M,S}) ->
    case pimsg:head_reader(R0, Bin) of
        {error,Rsn} ->
            {error, M:head_error(Rsn, S)};
        {continue,R} ->
            {ok, {head,R,M,S}};
        {done,StatusLn,Headers,Rest} ->
            M:head(StatusLn, Headers, S),
            case M:body_length(StatusLn, Headers, S) of
                {error,_}=Err ->
                    Err;
                {ok,Len} ->
                    read(Rest, {body, pimsg:body_reader(Len), M, S})
            end
    end;

read(Bin0, {body,R0,M,S0}) ->
    case pimsg:body_reader(R0, Bin0) of
        {error,Rsn} ->
            {error, M:body_error(Rsn, S0)};
        {continue,Bin,R} ->
            M:body(Bin, S0),
            {ok, {body,R,M,S0}};
        {done,Bin,Rest} ->
            case Bin of
                empty -> ok;
                _ -> M:body(Bin)
            end,
            S = M:reset(S0),
            read(Rest, {head, pimsg:head_reader(), M, S})
    end.
