%%% http_res_sock
%%% State machine.
%%% Sends HTTP requests from 'http_pipe' as tuples.
%%% Receives HTTP responses from the socket as binary.

-module(http_res_sock).
-behavior(gen_statem).
-include("../include/phttp.hrl").
-define(ACTIVE_TIMEOUT, 5000).
-define(IDLE_TIMEOUT, 60000).

-record(data, {target, socket, reader, queue=[], closed=open}).
-export([start_link/1, stop/1]).
-export([init/1, callback_mode/0, handle_event/4]).

%%%
%%% EXTERNAL INTERFACE
%%%

start_link({Proto,Host,Port}) ->
    gen_statem:start_link(?MODULE, [self(), {Proto,binary_to_list(Host),Port}], []).
    %%case Host of
    %%    <<"v.redd.it">> ->
    %%        gen_statem:start_link(?MODULE, [self(), {Proto,binary_to_list(Host),Port}], [{debug,[trace]}]);
    %%    _ -> gen_statem:start_link(?MODULE, [self(), {Proto,binary_to_list(Host),Port}], [])
    %%end.

stop(Pid) ->
    try
        gen_statem:stop(Pid)
    catch
        exit:noproc -> ok
    end.

%%%
%%% BEHAVIOR CALLBACKS
%%%

callback_mode() -> [handle_event_function, state_enter].

init([Pid,T]) ->
    {ok, disconnected, #data{target=Pid}, {next_event,cast,{connect,T}}}.

%% Use enter events to choose between the idle timeout and active timeout.
%% Remember that we are idle only when we are not in the middle of receiving
%% a response AND we are not waiting to receive a response to a request
%% we have previously sent.

%% In the eof state we are not in the middle of receiving a response.
%% Ensure that we should not be receiving a response before enabling
%% the idle timeout.
handle_event(enter, _, eof, #data{queue=[]}) ->
    {keep_state_and_data,
     {state_timeout,?IDLE_TIMEOUT,idle}};

handle_event(enter, _, eof, _) ->
    {keep_state_and_data,
     {state_timeout,?ACTIVE_TIMEOUT,active}};

handle_event(enter, _, HttpState, _)
  when HttpState == head; HttpState == body ->
    {keep_state_and_data, {state_timeout,?ACTIVE_TIMEOUT,active}};

handle_event(enter, _, _, _) ->
    keep_state_and_data;

handle_event(state_timeout, idle, _, _) ->
    %% Use the idle timeout to automatically close.
    {stop, shutdown};

handle_event(state_timeout, active, _, _) ->
    %% Only a timeout in 'eof' is not considered an error.
    {stop, {shutdown,timeout}};

%%%
%%% disconnected state: connect socket to protocol/host/port provided by start_link
%%%

handle_event(cast, {connect,{http,Host,Port}}, disconnected, D) ->
    case gen_tcp:connect(Host, Port, [{active,true},binary,{packet,0},
                                      {keepalive,true},
                                      {exit_on_close,false}],
                         ?CONNECT_TIMEOUT) of
        {error,timeout} ->
            {stop,{shutdown,timeout}};
        {error,nxdomain} ->
            {next_state,nxdomain,Host};
        {error,Reason} ->
            {stop,Reason};
        {ok,Socket} ->
            {next_state,eof,D#data{socket={tcp,Socket}}}
    end;

handle_event(cast, {connect,{https,Host,Port}}, disconnected, D) ->
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0},
                                  {keepalive,true},
                                  {exit_on_close,false}],
                     ?CONNECT_TIMEOUT) of
        {error,timeout} ->
            {stop,{shutdown,timeout}};
        {error,nxdomain} ->
            {next_state,nxdomain,Host};
        {error,Reason} ->
            {stop,Reason};
        {ok,Socket} ->
            ssl:setopts(Socket, [{active,true}]),
            {next_state,eof,D#data{socket={ssl,Socket}}}
    end;

%%%
%%% Error message generator
%%%

handle_event(info, {http_pipe,Res,eof}, nxdomain, Host) ->
    send_text(Res, "Unknown domain name: "++Host),
    {stop,shutdown};

handle_event(info, {http_pipe,_,_}, nxdomain, _) ->
    keep_state_and_data;

%%%
%%% TCP/SSL messages
%%%

handle_event(info, {A,_,_}, eof, D)
  when A == tcp; A == ssl ->
    {next_state, head, D#data{reader=pimsg:head_reader()}, postpone};

handle_event(info, {A,_,Bin}, head, D0)
  when A == tcp; A == ssl ->
    case pimsg:head_reader(D0#data.reader, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            {keep_state,D0#data{reader=Reader},{state_timeout,?ACTIVE_TIMEOUT,active}};
        {done,StatusLn,Headers,Rest} ->
            {ok, [_HttpVer, Code, _]} = phttp:nsplit(3, StatusLn, <<" ">>),
            handle_head(Code, StatusLn, Headers, Rest, D0)
    end;

handle_event(info, {A,_,Bin1}, body, D)
  when A == tcp; A == ssl ->
    case pimsg:body_reader(D#data.reader, Bin1) of
        {error,Reason} ->
            {stop,Reason};
        {continue,?EMPTY,Reader} ->
            {keep_state,D#data{reader=Reader}};
        {continue,Bin2,Reader} ->
            {Req,_} = hd(D#data.queue),
            http_pipe:recv(Req, {body,Bin2}),
            {keep_state,D#data{reader=Reader},{state_timeout,?ACTIVE_TIMEOUT,active}};
        {done,Bin2,Rest} ->
            Q = D#data.queue,
            {Req,Hreq} = hd(Q),
            case Bin2 of
                ?EMPTY -> ok;
                _ -> http_pipe:recv(Req, {body,Bin2})
            end,
            Host = fieldlist:get_value(<<"host">>, Hreq#head.headers),
            ?TRACE(Req, Host, "<<", "EOF"),
            http_pipe:recv(Req, eof),
            %% Notify request_target that we have finished receiving the response for Req.
            %% This will remove it from the sent list.
            request_target:finish(D#data.target, Req),
            case D#data.closed of
                eof_on_close ->
                    %% This should never happen.
                    error(internal);
                close_on_eof ->
                    %% If the response had "Connection: close" then we are supposed to
                    %% disconnect the socket after receiving a response. We shutdown
                    %% so that we can *guarantee* that the pipeline is stopped.
                    ?DBG("body", closing),
                    {stop,shutdown};
                open ->
                    %% Pop the request off the queue after we receive a
                    %% *complete* response.
                    case Rest of
                        ?EMPTY ->
                            {next_state,eof, D#data{reader=undefined, queue=tl(Q)}};
                        _ ->
                            {next_state,eof, D#data{reader=undefined, queue=tl(Q)},
                             {next_event,info,{A,null,Rest}}}
                    end
            end
    end;

handle_event(info, {A,_}, _, D)
  when A =:= tcp_closed; A =:= ssl_closed ->
    case D#data.closed of
        eof_on_close ->
            {Res,_} = hd(D#data.queue),
            http_pipe:recv(Res, eof);
        _ ->
            ok
    end,
    {stop,shutdown};

handle_event(info, {A,_,Reason}, _, _)
  when A =:= tcp_error, A =:= ssl_error ->
    {stop,Reason};

%%%
%%% messages from http_pipe/piserver
%%%

handle_event(info, {http_pipe,_,_}, disconnected, _) ->
    {keep_state_and_data, postpone};

handle_event(info, {http_pipe,_Req,cancel}, _, D)
  when D#data.queue =:= [] ->
    %% Special case: Avoid breaking lists:last/1 with empty list.
    keep_state_and_data;

handle_event(info, {http_pipe,Req,cancel}, _, D) ->
    case lists:any(fun ({Req2,_}) when Req =:= Req2 -> true; (_) -> false end,
                   D#data.queue) of
        true ->
            %% The pipeline was broken! We have to cancel the request
            %% except for we have already sent some of it!
            {stop,{shutdown,reset}};
        false ->
            keep_state_and_data
    end;

handle_event(info, {http_pipe,_,_}, _, #data{closed=close_on_eof}) ->
    %% discard http_pipe events after the socket has been remotely closed
    keep_state_and_data;

handle_event(info, {http_pipe,Req,#head{}=Head}, _, D) ->
    %% Push a new request on the queue when we receive a message head from the
    %% pipeline.
    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
    ?TRACE(Req, Host, ">>", Head),
    pisock:send(D#data.socket, phttp:encode(Head)),
    Q = D#data.queue ++ [{Req,Head}],
    {keep_state, D#data{queue=Q}};

%% The request may have been popped off the queue already! This
%% happens when the response EOF is parsed *before* the request
%% EOF is received from the pipe.
%%
%%  http_pipe_req                            http_pipe_res
%%  =============                            =============
%%
%%  1. ->HEAD                ==>                  HEAD->
%%  2. ->EOF                 ==>
%%  3. <-HEAD               <==                   HEAD<-
%%  4. <-EOF                <==                   EOF<-
%%  5.                    (from #2)               EOF->

handle_event(info, {http_pipe,Req,eof}, _, _) ->
    %% Avoid trying to encode the 'eof' atom.
    ?TRACE(Req, '?', ">>", "EOF"),
    keep_state_and_data;

handle_event(info, {http_pipe,_Req,Term}, _, D) ->
    pisock:send(D#data.socket, phttp:encode(Term)),
    keep_state_and_data.

%%%
%%% INTERNAL FUNCTIONS
%%%

handle_head(<<"408">>, _StatusLn, _Headers, _Rest, _D0) ->
    %% 408 Request Timeout means that the server probably timed out before we
    %% sent a request. We shutdown and if we had any pending responses then
    %% they will be resent.
    {stop,{shutdown,reset}};

handle_head(Code, StatusLn, Headers, Rest, D0) ->
    ConnClosed = connection_close(Headers),
    {Req,Hreq} = hd(D0#data.queue),
    Hres = head(Hreq#head.method, Code, Headers, ConnClosed, StatusLn),
    Host = fieldlist:get_value(<<"host">>, Hreq#head.headers),
    ?TRACE(Req, Host, "<<", Hres),
    http_pipe:recv(Req, Hres),
    case Code of
        <<"101">> ->
            ?DBG(head, "101 Upgrade"),
            upgrade(Req, Headers, Rest, D0);
        _ ->
            CloseStatus = case {Hres#head.bodylen, ConnClosed} of
                              {until_closed,_} -> eof_on_close;
                              {_,true} -> close_on_eof;
                              {_,false} -> open
                          end,
            case CloseStatus of
                eof_on_close ->
                    ?TRACE(Req, Host, "<<", eof_on_close);
                close_on_eof ->
                    ?TRACE(Req, Host, "<<", close_on_eof);
                open ->
                    ok
            end,
            D = D0#data{reader=pimsg:body_reader(Hres#head.bodylen),
                        closed=CloseStatus},
            {next_state,body,D,{next_event,info,{tcp,null,Rest}}}
    end.

head(ReqMethod, Code, Headers, Closed, StatusLn) ->
    case body_length(ReqMethod, Code, Headers) of
        not_found ->
            case Closed of
                true ->
                    #head{method=ReqMethod, line=StatusLn, headers=Headers, bodylen=until_closed};
                false ->
                    exit({missing_length,StatusLn,Headers})
            end;
        Len ->
            #head{method=ReqMethod, line=StatusLn, headers=Headers, bodylen=Len}
    end.

body_length(Method, Code, Headers) ->
    %% the response length depends on the request method
    case response_length(Method, Code, Headers) of
        {ok,BodyLen} -> BodyLen;
        {error,{missing_length,_}} -> not_found
    end.

%%% Reference: RFC7230 3.3.3 p32
response_length(head, <<"200">>, _) -> {ok, 0}; % optimize 200
response_length(_, <<"200">>, Headers) -> pimsg:body_length(Headers);
response_length(_, <<"1",_,_>>, _) -> {ok, 0};
response_length(_, <<"204">>, _) -> {ok, 0};
response_length(_, <<"304">>, _) -> {ok, 0};
response_length(head, _, _) -> {ok, 0};
response_length(_, _, Headers) -> pimsg:body_length(Headers).

%%% TODO: double-check RFC7231 for other values
connection_close(Headers) ->
    Close = case fieldlist:get_value(<<"connection">>, Headers) of
                not_found ->
                    not_found;
                Bin ->
                    fieldlist:trimows(fieldlist:binary_lcase(Bin))
            end,
    case Close of
        <<"close">> ->
            true;
        _ ->
            false
    end.

send_text(Res, Text) ->
    Len = length(Text),
    L = [{"content-type", "text/plain"},
         {"content-length", integer_to_list(Len)}],
    Headers = fieldlist:from_proplist(L),
    H = #head{line = <<"HTTP/1.1 503 Bad Gateway">>,
              headers = Headers,
              bodylen = Len},
    http_pipe:recv(Res, H),
    http_pipe:recv(Res, {body,Text}),
    http_pipe:recv(Res, eof).

%%%
%%% WebSocket and raw binary (unparsed) sockets.
%%%

upgrade(Req, Headers, Rest, D) ->
    io:format("*DBG* ~p upgrading ~B~n", [self(), Req]),
    T = try
            case fieldlist:has_value(<<"upgrade">>, <<"websocket">>, Headers) of
                true ->
                    %% upgrade_ws might also throw(raw_sock)
                    upgrade_ws(Req, Headers, D#data.socket, Rest);
                false ->
                    throw(raw_sock)
            end
        catch
            raw_sock ->
                %% Fall back to using raw_sock
                upgrade_raw(Req, D#data.socket, Rest)
        end,
    case T of
        {ok,Msg} ->
            http_pipe:recv(Req, Msg),
            http_pipe:recv(Req, eof), % to make http_pipe cleanup
            request_target:finish(D#data.target, Req), % avoid request retry
            {stop,shutdown};
        {error,Rsn} ->
            {stop,Rsn}
    end.

upgrade_ws(Req, Headers, Sock, Rest) ->
    io:format("*DBG* ~p upgrade_ws~n", [self()]),
    MitmPid = ws_sock:start_mitm(Req),
    Exts = case fieldlist:get_lcase(<<"sec-websocket-extensions">>, Headers) of
               <<"permessage-deflate">> ->
                   %% TODO: handle deflate extension parameters
                   [{deflate,true}];
               not_found ->
                   [];
               _ ->
                   %% unknown extension(s), cannot be parsed
                   throw(raw_sock)
           end,
    Opts = [MitmPid,Exts],
    case ws_sock:start_server(Sock, Rest, Opts) of
        {ok,_} ->
            {ok,{upgrade,ws_sock,start_client,Opts}};
        {error,_} = Err ->
            Err
    end.

upgrade_raw(Req, Sock, Rest) ->
    io:format("*DBG* ~p upgrade_raw~n", [self()]),
    MitmPid = raw_sock:start_mitm(Req),
    Opts = [MitmPid],
    case raw_sock:start_server(Sock, Rest, Opts) of
        {ok,_} ->
            {ok,{upgrade,raw_sock,start_client,Opts}};
        {error,_} = Err ->
            Err
    end.
