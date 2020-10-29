%%% HTTP 1.1 response message callback module.
%%%

-module(http11_res).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-record(state, {connection=keepalive,
                pipeline=pipipe:new(),
                waitqueue=[], pid, upgrading=false}).
-import(lists, [any/2, reverse/1]).

-export([start_link/1, read/2, push/3, shutdown/2]).
-export([head/3, body/2, reset/1]).

start_link([RequestTargetPid]) ->
    http11_statem:start_link(?MODULE, #state{pid=RequestTargetPid},
                             {?RESPONSE_TIMEOUT, 60000}, []).

read(Pid, Bin) ->
    http11_statem:read(Pid, Bin).

push(Pid, Sock, {Req,Term}) ->
    Fun = fun (S) ->
                  P0 = S#state.pipeline,
                  case Term of
                      #head{} ->
                          P = pipipe:append(Req, Term, pipipe:push(Req, P0)),
                          %% an upgrade request will stall the pipeline until response
                          case fieldlist:get_value(<<"upgrade">>,
                                                   Term#head.headers) of
                              not_found ->
                                  S#state{pipeline=P,upgrading=true};
                              _ ->
                                  S#state{pipeline=P,upgrading=false}
                          end;
                      {body,done} ->
                          %% A request is done, flush the pipeline. Moves finished
                          %% requests to the (response) waitlist queue.
                          try
                              %% NOTE: flush should always succeed, the
                              %% pipeline is used to prevent overlapping
                              %% #head{}s from being sent before the previous
                              %% body is finished.
                              {P,Q2} = flush(Sock, pipipe:close(Req, P0)),
                              %% ensure we switch to active timeout
                              http11_statem:activate(Pid),
                              Q1 = S#state.waitqueue,
                              S#state{pipeline=P, waitqueue=Q1++Q2}
                          catch
                              closed -> % thrown by send, below
                                  %% Gracefully shutdown to receive as much as the
                                  %% pipeline as possible.
                                  ?DBG("push", closed),
                                  http11_statem:shutdown(Pid, closed),
                                  S
                          end;
                      {body,_} ->
                          S#state{pipeline=pipipe:append(Req, Term, P0)}
                  end
          end,
    http11_statem:swap_state(Pid, Fun).

shutdown(Pid, Reason) ->
    http11_statem:shutdown(Pid, Reason).

%%% sending data over sockets
%%%

flush(Sock,P0) ->
    case pipipe:pop(P0) of
        not_done ->
            not_done;
        {Req,[H|_]=L,P} ->
            %%?DBG("flush", [{request,Req},{line,H#head.line}]),
            send(Sock, L),
            flush(Sock,P,[{Req,H}])
    end.

flush(Sock, P0, Q) ->
    case pipipe:pop(P0) of
        not_done ->
            {P0, reverse(Q)};
        {Req,[H|_]=L,P} ->
            %%?DBG("flush", [{request,Req},{line,H#head.line}]),
            send(Sock, L),
            flush(Sock, P, [{Req,H}|Q])
    end.

send(_Sock, []) ->
    ok;

send(Sock, [Term|L]) ->
    %% OK, remember we are calling this DEEP INSIDE of the http11_statem process!!
    case send_(Sock, http11_statem:encode(Term)) of
        {error,closed} ->
            %% caught by http11_statem (this happens alot)
            throw(closed);
        {error,Reason} ->
            %% not recoverable
            exit(Reason);
        ok ->
            send(Sock, L)
    end.

send_({tcp,Sock}, Bin) ->
    gen_tcp:send(Sock, Bin);

send_({ssl,Sock}, Bin) ->
    ssl:send(Sock, Bin).

%%%
%%% CALLBACK FUNCTIONS
%%%

%%head(_, {_,[]}) ->
    %% HTTP message received during no active request.
    %% TODO: parse HTTP error message and convert to an atom.
    %%exit(unexpected_response);

head(StatusLn, Headers, S) ->
    %%?DBG("head", [{line, StatusLn}]),
    {Req,ReqHead} = hd(S#state.waitqueue),
    Method = ReqHead#head.method,
    Len = body_length(StatusLn, Headers, ReqHead),
    ResHead = #head{method=Method, line=StatusLn, headers=Headers, bodylen=Len},
    pievents:respond(Req, ResHead),
    case upgraded(ResHead) of
        false ->
            {ResHead, S#state{connection=connection(Headers)}};
        {Proto1,Args1,Proto2,Args2} ->
            %% The state machine must be replaced by another on BOTH ends.
            %% EXIT message is emitted from the http11_statem process.
            pievents:upgrade_protocol(Req, Proto1, Args1),
            exit({shutdown,{upgraded,Proto2,Args2}})
    end.

body(Chunk, S) ->
    {Req,_} = hd(S#state.waitqueue),
    pievents:respond(Req, {body,Chunk}),
    S.

%%% reset/1 is called by http11_statem

reset(#state{connection=closed} = S) ->
    %% The last response requested that we close the connection.
    {Req,_H} = hd(S#state.waitqueue),
    request_target:request_done(S#state.pid, Req),
    pievents:close_response(Req),
    exit({shutdown,closed});

reset(#state{connection=keepalive} = S) ->
    Q = S#state.waitqueue,
    {Req,_H} = hd(Q),
    request_target:request_done(S#state.pid, Req),
    pievents:close_response(Req),
    S#state{waitqueue=tl(Q)}.

%%%
%%% INTERNAL FUNCTIONS
%%%

body_length(StatusLn, Headers, ReqH) ->
    %% the response length depends on the request method
    Method = ReqH#head.method,
    case response_length(Method, StatusLn, Headers) of
        {ok,0} -> 0;
        {ok,BodyLen} -> BodyLen;
        {error,{missing_length,_}} ->
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
    case phttp:nsplit(3, StatusLn, <<" ">>) of
        {ok,[_,Status,_]} ->
            Status;
        {error,Reason} ->
            error(Reason)
    end.

%%% TODO: double-check RFC7231 for other values
connection(Headers) ->
    case fieldlist:get_value(<<"connection">>, Headers) of
        <<"close">> ->
            closed;
        _ ->
            keepalive
    end.

upgraded(H) ->
    %% check the least likely condition first
    case response_code(H#head.line) of
        <<"101">> ->
            Upgrade = fieldlist:get_value(<<"upgrade">>, H#head.headers),
            Connection = fieldlist:get_value_split(<<"connection">>, H#head.headers),
            case {Upgrade,Connection} of
                {not_found,_} ->
                    ?LOG_WARNING("101 Switching Protocols "++
                                 "is missing Upgrade field."),
                    false;
                {_,not_found} ->
                    ?LOG_WARNING("101 Switching Protocols "++
                                 "is missing Connection field."),
                    false;
                _ ->
                    case any(fun (<<"upgrade">>)->true; (_)->false end,
                             Connection) of
                        false ->
                            ?LOG_WARNING("101 Switching Protocols "++
                                         "has invalid Connection field."),
                            false;
                        true ->
                            upgrade_protocol(Upgrade)
                    end
            end;
        _ ->
            false
    end.

%% TODO: figure out what args to start with
%%upgrade_protocol(<<"websocket">>) ->
    %%{ws_req,[], ws_res,[]};

%%% Unknown protocol, fall back to raw TCP send/recv
upgrade_protocol(_) ->
    %% use Req as a unique identifier
    Pid = spawn(raw_stream, middleman, []),
    {raw_stream,[Pid], raw_stream,[Pid]}.
