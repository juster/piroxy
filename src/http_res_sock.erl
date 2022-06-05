%%% http_res_sock
%%% State machine.
%%% Sends HTTP requests received as transmit messages.
%%% Receives HTTP responses from the socket as binary.

-module(http_res_sock).
-behavior(gen_statem).
-include("../include/pihttp_lib.hrl").
-define(ACTIVE_TIMEOUT, 5000).
-define(IDLE_TIMEOUT, 60000).

-record(data, {targetpid, socket, reader, queue=[], closed=open}).
-export([start_link/1,stop/1]).
-export([init/1, callback_mode/0, handle_event/4]).

%%%
%%% EXTERNAL INTERFACE
%%%

start_link({Host,Port,Secure}) ->
    gen_statem:start_link(?MODULE, [self(), {binary_to_list(Host),Port,Secure}], []).
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
    {ok, disconnected, #data{targetpid=Pid}, {next_event,cast,{connect,T}}}.

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

handle_event(cast, {connect,{Host,Port,false}}, disconnected, D) ->
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

handle_event(cast, {connect,{Host,Port,true}}, disconnected, D) ->
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0},
                                  {keepalive,true},
                                  {verify,verify_none},
                                  {exit_on_close,false}], ?CONNECT_TIMEOUT) of
        {error,timeout} ->
            {stop,{shutdown,timeout}};
        {error,nxdomain} ->
            {next_state,nxdomain,Host};
        {error,Reason} ->
            {stop,Reason};
        {ok,Socket} ->
            {next_state,eof,D#data{socket={ssl,Socket}}}
    end;

%%%
%%% TCP/SSL messages
%%%

handle_event(info, {A,_,_}, eof, D)
  when A == tcp; A == ssl ->
    {next_state, head, D#data{reader=pihttp_lib:head_reader()}, postpone};

handle_event(info, {A,_,Bin}, head, D)
  when A == tcp; A == ssl ->
    case pihttp_lib:head_reader(D#data.reader, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            {keep_state,D#data{reader=Reader},{state_timeout,?ACTIVE_TIMEOUT,active}};
        {done,StatusLn,Headers,Rest} ->
            case pihttp_lib:split_status_line(StatusLn) of
                {ok,{{1,X},Code,_Etc}} when X =:= 0; X =:= 1 ->
                    handle_head(Code, StatusLn, Headers, Rest, D);
                {ok,{Ver,_,_}} ->
                    {stop,{badversion,Ver},D};
                {error,Rsn} ->
                    {stop,Rsn,D}
            end
    end;

handle_event(info, {A,_,Bin1}, body, D)
  when A == tcp; A == ssl ->
    case pihttp_lib:body_reader(D#data.reader, Bin1) of
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
            request_target:finish(D#data.targetpid, Req),
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

handle_event(info, {transmit,Res,eof}, nxdomain, Host) ->
    send_error(Res, "Unknown domain name: "++Host),
    {stop,shutdown};

handle_event(info, {transmit,_,_}, nxdomain, _) ->
    keep_state_and_data;

handle_event(info, {transmit,_,_}, disconnected, _) ->
    {keep_state_and_data, postpone};

handle_event(info, {transmit,_Req,cancel}, _, D)
  when D#data.queue =:= [] ->
    %% Special case: Avoid breaking lists:last/1 with empty list.
    keep_state_and_data;

handle_event(info, {transmit,Req,cancel}, _, D) ->
    case lists:any(fun ({Req2,_}) when Req =:= Req2 -> true; (_) -> false end,
                   D#data.queue) of
        true ->
            %% The pipeline was broken! We have to cancel the request
            %% except for we have already sent some of it!
            {stop,{shutdown,reset}};
        false ->
            keep_state_and_data
    end;

handle_event(info, {transmit,_,_}, _, #data{closed=close_on_eof}) ->
    %% discard http_pipe events after the socket has been remotely closed
    keep_state_and_data;

handle_event(info, {transmit,Req,Head = #head{}}, _, D) ->
    %% Push a new request on the queue when we receive a message head from the
    %% pipeline.
    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
    ?TRACE(Req, Host, ">>", Head),
    pisock_lib:send(D#data.socket, pihttp_lib:encode(Head)),
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

handle_event(info, {transmit,Req,eof}, _, _) ->
    %% Avoid trying to encode the 'eof' atom.
    ?TRACE(Req, '?', ">>", "EOF"),
    keep_state_and_data;

handle_event(info, {transmit,_Req,Term}, _, D) ->
    pisock_lib:send(D#data.socket, pihttp_lib:encode(Term)),
    keep_state_and_data.

%%%
%%%
%%% INTERNAL FUNCTIONS
%%%

handle_head(408, _StatusLn, _Headers, _Rest, _D0) ->
    %% 408 Request Timeout means that the server probably timed out before we
    %% sent a request. We shutdown and if we had any pending responses then
    %% they will be resent.
    {stop,{shutdown,reset}};

%%% 101 often means to upgrade to a WebSocket.
handle_head(101, StatusLn, Headers, Rest, D) ->
    ?DBG(head, "101 Upgrade"),
    {Req,Hreq} = hd(D#data.queue),
    ConnClosed = connection_close(Headers),
    case head(Hreq#head.method,101,Headers,ConnClosed,StatusLn) of
        {ok,Hres} ->
            http_pipe:recv(Req,Hres),
            upgrade(Req,Headers,Rest,D);
        {error,Rsn} ->
            {stop,Rsn,D}
    end;

handle_head(Code, StatusLn, Headers, Rest, D0) ->
    ConnClosed = connection_close(Headers),
    {Req,Hreq} = hd(D0#data.queue),
    case head(Hreq#head.method, Code, Headers, ConnClosed, StatusLn) of
        {ok,Hres} ->
            Host = fieldlist:get_value(<<"host">>, Hreq#head.headers),
            ?TRACE(Req, Host, "<<", Hres),
            http_pipe:recv(Req, Hres),
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
            D = D0#data{reader=pihttp_lib:body_reader(Hres#head.bodylen),
                        closed=CloseStatus},
            {next_state,body,D,{next_event,info,{tcp,null,Rest}}};
        {error,Rsn} ->
            {stop,Rsn,D0}
    end.

head(ReqMethod, Code, Headers, Closed, StatusLn) ->
    case response_length(ReqMethod, Code, Headers) of
        {error,_} ->
            case Closed of
                true ->
                    %% Connection was closed and so we will just read until the end of input.
                    {ok,#head{method=ReqMethod, line=StatusLn, headers=Headers, bodylen=until_closed}};
                false ->
                    {error,{badhead,StatusLn,Headers}}
            end;
        {ok,Len} ->
            {ok,#head{method=ReqMethod, line=StatusLn, headers=Headers, bodylen=Len}}
    end.

%%% Reference: RFC7230 3.3.3 p32
response_length(head, 200, _) -> {ok, 0}; % avoid the next match on code 200 for HEAD responses
response_length(_, 200, Headers) -> pihttp_lib:body_length(Headers);
response_length(_, N, _) when 100 =< N, N < 200 -> {ok, 0}; % 1XX responses
response_length(_, 204, _) -> {ok, 0};
response_length(_, 304, _) -> {ok, 0};
response_length(head, _, _) -> {ok, 0};
response_length(_, _, Headers) -> pihttp_lib:body_length(Headers).

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

send_error(Res, Text) ->
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

upgrade(Req, Headers, Rest, #data{socket=Sock} = D) ->
    io:format("*DBG* ~p upgrading ~B~n", [self(), Req]),
    Opts1 = ws_sock:upgrade_options(Headers),
    Logging = case proplists:get_value(mode,Opts1) of
                  ws ->
                      recv;
                  raw ->
                      false
              end,
    Opts2 = [{id,Req},{socket,Sock},{logging,Logging},{buffer,Rest}|Opts1],
    case ws_sock:start(Opts2) of
        {ok,Pid} ->
            %% We send the response to http_req_sock through http_pipe, so that
            %% it is received in the proper order in case of pipelining.
            http_pipe:recv(Req, {upgrade_socket,Pid,Opts1}),
            http_pipe:close(Req),
            request_target:finish(D#data.targetpid, Req), % avoids request retry
            {stop,shutdown};
        {error,Rsn} ->
            {stop,Rsn}
    end.
