%%% HTTP 1.1 response message callback module.
%%%

-module(http11_res).
-include("../include/phttp.hrl").

-export([new/0, read/2, encode/1, push/3]).
-export([head/3, body/2, reset/1]).

new() ->
    http11_statem:start_link(?MODULE, {false,[]}).

read(Pid, Bin) ->
    http11_statem:read(Pid, Bin).

encode(Bin) ->
    http11_statem:encode(Bin).

push(Pid, Req, ReqHead) ->
    {Dc,Q} = http11_statem:cb_state(Pid),
    http11_statem:cb_state(Pid, {Dc,Q++[{Req,ReqHead}]}).

%%%
%%% CALLBACK FUNCTIONS
%%%

%%head(_, {_,[]}) ->
    %% HTTP message received during no active request.
    %% TODO: parse HTTP error message and convert to an atom.
    %%exit(unexpected_response);

head(StatusLn, Headers, {Dc0,Q}) ->
    {Req,ReqHead} = hd(Q),
    Method = ReqHead#head.method,
    Len = body_length(StatusLn, Headers, ReqHead),
    ResHead = #head{method=Method, line=StatusLn,
                    headers=Headers, bodylen=Len},
    pievents:respond(Req, ResHead),
    Dc = Dc0 or closed(Headers),
    {ResHead, {Dc,Q}}.

body(Chunk, {_,Q} = State) ->
    {Req,_} = hd(Q),
    pievents:respond(Req, {body,Chunk}),
    State.

%%% reset/1 is called by http11_stream

reset({true,Q}) ->
    %% The last response requested that we close the connection.
    {Req,_} = hd(Q),
    ?DBG("reset", [close_response, {disconnect,true},{req,Req}]),
    pievents:close_response(Req),
    %%lists:foreach(fun ({Req_,_}) ->
    %%                      pievents:reset_request(Req_)
    %%              end, Q),
    shutdown;

reset({false,Q}) ->
    {Req,_} = hd(Q),
    ?DBG("reset", [close_response, {disconnect,false},{req,Req}]),
    pievents:close_response(Req),
    {false,tl(Q)}.

%%%
%%% INTERNAL FUNCTIONS
%%%

body_length(StatusLn, Headers, ReqH) ->
    %% the response length depends on the request method
    Method = ReqH#head.method,
    case response_length(Method, StatusLn, Headers) of
        {ok,0} -> 0;
        {ok,BodyLen} -> BodyLen;
        {error,missing_length} ->
            exit({missing_length,StatusLn,Headers})
    end.

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
closed(Headers) ->
    case fieldlist:get_value(<<"connection">>, Headers) of
        <<"close">> ->
            true;
        _ ->
            false
    end.
