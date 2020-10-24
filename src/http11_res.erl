%%% HTTP 1.1 response message callback module.
%%%

-module(http11_res).
-include("../include/phttp.hrl").

-export([start_link/1, stop/2, read/2, encode/1, push/3, close/2]).
-export([head/3, body/2, reset/1]).

start_link(RequestTargetPid) ->
    http11_statem:start_link(?MODULE, {false,[],RequestTargetPid}, []).

stop(Pid, Reason) ->
    http11_statem:stop(Pid, Reason).

read(Pid, Bin) ->
    http11_statem:read(Pid, Bin).

encode(Bin) ->
    http11_statem:encode(Bin).

push(Pid, Req, ReqHead) ->
    Fun = fun ({Dc,Q,RTPid}) ->
                  {Dc, Q++[{Req,ReqHead}], RTPid}
          end,
    http11_statem:replace_cb_state(Pid, Fun).

close(Pid, Reason) ->
    http11_statem:close(Pid, Reason).

%%%
%%% CALLBACK FUNCTIONS
%%%

%%head(_, {_,[]}) ->
    %% HTTP message received during no active request.
    %% TODO: parse HTTP error message and convert to an atom.
    %%exit(unexpected_response);

head(StatusLn, Headers, {_,Q,RTPid}) ->
    %%?DBG("head", [{line, StatusLn}]),
    {Req,ReqHead} = hd(Q),
    Method = ReqHead#head.method,
    Len = body_length(StatusLn, Headers, ReqHead),
    ResHead = #head{method=Method, line=StatusLn,
                    headers=Headers, bodylen=Len},
    pievents:respond(Req, ResHead),
    Dc = closed(Headers),
    {ResHead, {Dc,Q,RTPid}}.

body(Chunk, {_,Q,_} = State) ->
    {Req,_} = hd(Q),
    pievents:respond(Req, {body,Chunk}),
    State.

%%% reset/1 is called by http11_stream

reset({true,Q,RTPid}) ->
    %% The last response requested that we close the connection.
    {Req,H} = hd(Q),
    %%?DBG("reset", [{disconnect,true},{req,Req},{line,H#head.line}]),
    request_target:request_done(RTPid, Req),
    pievents:close_response(Req),
    %%lists:foreach(fun ({Req_,_}) ->
    %%                      pievents:reset_request(Req_)
    %%              end, Q),
    exit({shutdown,closed});

reset({false,Q,RTPid}) ->
    {Req,H} = hd(Q),
    %%?DBG("reset", [{disconnect,false},{req,Req},{line,H#head.line}]),
    request_target:request_done(RTPid, Req),
    pievents:close_response(Req),
    {false,tl(Q),RTPid}.

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
    %%?DBG("closed", [{connection,fieldlist:get_value(<<"connection">>,Headers)}]),
    case fieldlist:get_value(<<"connection">>, Headers) of
        <<"close">> ->
            true;
        _ ->
            false
    end.
