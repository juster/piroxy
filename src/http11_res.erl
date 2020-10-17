%%% HTTP 1.1 response message callback module.
%%%

-module(http11_res).
-include("../include/phttp.hrl").

-export([init/1, head/3, body/2, reset/1]).

%%%
%%% CALLBACK FUNCTIONS
%%%

init([]) ->
    {ok, {false,[]}}.

head({_,[]}, _StatusLn, _Headers) ->
    %% HTTP message received during no active request.
    %% TODO: parse HTTP error message and convert to an atom.
    {error,unexpected_response};

head({Dc0,Q}, StatusLn, Headers) ->
    [{Req,ReqHead}|_] = Q,
    Method = ReqHead#head.method,
    try
        Len = case response_length(Method, StatusLn, Headers) of
                  {ok,0} -> 0;
                  {ok,BodyLen} -> BodyLen;
                  {error,missing_length} ->
                      throw({error,{missing_length,StatusLn,Headers}})
              end,
        ResHead = #head{method=Method, line=StatusLn,
                        headers=Headers, bodylen=Len},
        pievents:respond(Req, ResHead),
        Dc = Dc0 or disconnect(Headers),
        {ok, ResHead, {Dc,Q}}
    catch
        Any -> Any
    end.

body({_,Q}, Chunk) ->
    {Req,_} = hd(Q),
    pievents:respond(Req, {body,Chunk}),
    ok.

%%% reset/1 is called by http11_stream

reset({true,Q0}) ->
    %% The last response requested that we close the connection.
    [{Req,_}|Q] = Q0,
    pievents:close_response(Req),
    lists:foreach(fun ({Req1,_}) ->
                          pievents:fail_request(Req1, connreset)
                  end, Q),
    shutdown;

reset({false,Q0}) ->
    [{Req,_}|Q] = Q0,
    pievents:close_response(Req),
    {ok,{false,Q}}.

%%%
%%% INTERNAL FUNCTIONS
%%%

response_length_(head, <<"200">>, _) -> {ok, 0};
response_length_(_, <<"200">>, Headers) -> pimsg:body_length(Headers);
response_length_(_, <<"1",_,_>>, _) -> {ok, 0};
response_length_(_, <<"204">>, _) -> {ok, 0};
response_length_(_, <<"304">>, _) -> {ok, 0};
response_length_(head, _, _) -> {ok, 0};
response_length_(_, _, ResHeaders) -> pimsg:body_length(ResHeaders).

response_length(Method, Line, Headers) ->
    response_length_(Method, response_code(Line), Headers).

response_code(StatusLn) ->
    {ok,[_,Status,_]} = phttp:nsplit(3, StatusLn, <<" ">>),
    Status.

%%% TODO: improve this and verify that it works properly
disconnect(Headers) ->
    case fieldlist:get_value(<<"connection">>, Headers) of
        <<"disconnect">> ->
            true;
        _ ->
            false
    end.
