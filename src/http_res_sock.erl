%%% http_res_sock
%%% State machine.
%%% Sends HTTP requests from 'http_pipe' as tuples.
%%% Receives HTTP responses from the socket as binary.

-module(http_res_sock).
-behavior(gen_statem).
-include("../include/phttp.hrl").
-define(ACTIVE_TIMEOUT, 5000).
-define(IDLE_TIMEOUT, 60000).

-record(data, {target, socket, reader, queue=[], closed=false}).
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

%% use enter events to choose between the idle timeout and active timeout
handle_event(enter, _, eof, _) ->
    {keep_state_and_data,
     {state_timeout,?IDLE_TIMEOUT,idle}};

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
        {error,Reason} ->
            {stop,Reason};
        {ok,Socket} ->
            ssl:setopts(Socket, [{active,true}]),
            {next_state,eof,D#data{socket={ssl,Socket}}}
    end;

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
            {Req,Hreq} = hd(D0#data.queue),
            {ok, [_HttpVer, Code, _]} = phttp:nsplit(3, StatusLn, <<" ">>),
            Hres = head(Code, StatusLn, Headers, Hreq),
            Host = fieldlist:get_value(<<"host">>, Hreq#head.headers),
            ?TRACE(Req, Host, "<<", Hres),
            http_pipe:recv(Req, Hres),
            case Code of
                <<"101">> ->
                    %%Proto = fieldlist:get_value(<<"upgrade">>, Hres#head.headers),
                    %%if
                    %%    is_binary(Proto),
                    %%    fieldlist:binary_lcase(Proto) == <<"websocket">> ->
                    %%        piroxy_events:recv(Req, http, {upgrade,raw});
                    %%    _ ->
                    %%        piroxy_events:recv(Req, http, {upgrade,raw});
                    %%;
                    %% TODO: create a separate session ID generator?
                    ?DBG(body, "101 Upgrade"),
                    MitmPid = raw_sock:start_mitm(),
                    Args = [null,MitmPid],
                    raw_sock:start(D0#data.socket, Args),
                    http_pipe:recv(Req, {upgrade,raw_sock,Args}),
                    request_target:finish(D0#data.target, Req),
                    {stop,shutdown};
                _ ->
                    Closed = connection_close(Hres),
                    D = D0#data{reader=pimsg:body_reader(Hres#head.bodylen), closed=Closed},
                    {next_state,body,D,{next_event,info,{A,null,Rest}}}
            end
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
                true ->
                    %% If the response had "Connection: close" then we are supposed to
                    %% disconnect the socket after receiving a response.
                    ?DBG("body", closing),
                    {stop,shutdown};
                false ->
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
  when A == tcp_closed; A == ssl_closed ->
    case D#data.queue of
        [] ->
            {stop,shutdown};
        _ ->
            {keep_state,D#data{closed=true}}
    end;

handle_event(info, {A,_,Reason}, _, _)
  when A == tcp_error, A == ssl_error ->
    {stop,Reason};

%%%
%%% messages from http_pipe/piserver
%%%

handle_event(info, {http_pipe,_,_}, disconnected, _) ->
    {keep_state_and_data, postpone};

handle_event(info, {http_pipe,_,_}, _, #data{closed=true}) ->
    %% discard http_pipe events after the socket has been remotely closed
    keep_state_and_data;

handle_event(info, {http_pipe,Req,#head{}=Head}, _, D) ->
    %% pipeline the next request ASAP
    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
    ?TRACE(Req, Host, ">>", Head),
    send(D#data.socket, Head),
    Q = D#data.queue ++ [{Req,Head}],
    {keep_state, D#data{queue=Q}};

handle_event(info, {http_pipe,Req,eof}, _, D) ->
    %% Avoid trying to encode the 'eof' atom.
    {Req,H} = lists:last(D#data.queue),
    Host = fieldlist:get_value(<<"host">>, H#head.headers),
    ?TRACE(Req, Host, ">>", "EOF"),
    keep_state_and_data;

handle_event(info, {http_pipe,_Req,Term}, _, D) ->
    send(D#data.socket, Term),
    keep_state_and_data.

%%%
%%% INTERNAL FUNCTIONS
%%%

send({tcp,Sock}, Term) ->
    gen_tcp:send(Sock, phttp:encode(Term));

send({ssl,Sock}, Term) ->
    ssl:send(Sock, phttp:encode(Term)).

head(Code, StatusLn, Headers, Head) ->
    Method = Head#head.method,
    case body_length(Method, Code, Headers) of
        not_found ->
            exit({missing_length,StatusLn,Headers});
        Len ->
            #head{method=Method, line=StatusLn, headers=Headers, bodylen=Len}
    end.

body_length(Method, Code, Headers) ->
    %% the response length depends on the request method
    case response_length(Method, Code, Headers) of
        {ok,BodyLen} -> BodyLen;
        _ -> not_found
    end.

%%% Reference: RFC7230 3.3.3 p32
response_length(head, <<"200">>, _) -> {ok, 0}; % optimize 200
response_length(_, <<"200">>, Headers) -> pimsg:body_length(Headers);
response_length(_, <<"1",_,_>>, _) -> {ok, 0};
response_length(_, <<"204">>, _) -> {ok, 0};
response_length(_, <<"304">>, _) -> {ok, 0};
response_length(head, _, _) -> {ok, 0};
response_length(_, _, ResHeaders) -> pimsg:body_length(ResHeaders).

%%% TODO: double-check RFC7231 for other values
connection_close(#head{headers=Headers}) ->
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
