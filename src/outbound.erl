-module(outbound).

-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-import(erlang, [system_time/0, convert_time_unit/3]).

-record(state, {status, socket, ssl, rstate=null, close=false,
                req=null, timer, lastrecv}).

-export([connect/3, new_request/1, start/3]).

%%% external functions
%%%

connect(http, Host, Port) ->
    ?DBG("connect", {http,Host,Port}),
    spawn_link(fun () -> outbound:start(binary_to_list(Host), Port, false) end);

connect(https, Host, Port) ->
    ?DBG("connect", {https,Host,Port}),
    spawn_link(fun () -> outbound:start(binary_to_list(Host), Port, true) end).

%% notify the outbound Pid that a new request is ready for it to send/recv
new_request(Pid) ->
    Pid ! new_request,
    ok.

%%% internal functions
%%%

start(Host, Port, false) ->
    {ok,Timer} = timer:send_interval(100, heartbeat),
    case gen_tcp:connect(Host, Port, [{active,true},binary,{packet,0}],
                         ?CONNECT_TIMEOUT) of
        {error, Reason} -> exit(Reason);
        {ok, Sock} ->
            State = clock_recv(#state{status=idle, socket=Sock, ssl=false, timer=Timer}),
            loop(State)
    end;

start(Host, Port, true) ->
    {ok,_} = timer:send_interval(100, heartbeat),
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0}],
                     ?CONNECT_TIMEOUT) of
        {error,Reason} -> exit(Reason);
        {ok,Sock} ->
            ssl:setopts(Sock, [{active,true}]),
            State = clock_recv(#state{status=idle, socket=Sock, ssl=true}),
            loop(State)
    end.

loop(State) ->
    receive
        new_request ->
            next_request(State);
        {tcp_closed, _} ->
            exit(closed);
        {ssl_closed, _} ->
            exit(closed);
        {tcp_error, Reason} ->
            exit(Reason);
        {ssl_error, Reason} ->
            exit(Reason);
        {tcp, _Sock, Data} ->
            recv_data(Data, State);
        {ssl, _Sock, Data} ->
            ?DBG("loop", ssl),
            recv_data(Data, State);
        heartbeat ->
            heartbeat(State);
        Any ->
            exit({unknown_msg,Any})
    end.

recv_data(Data, State) ->
    case State#state.status of
        head ->
            head_data(Data, clock_recv(State));
        body ->
            body_data(Data, clock_recv(State));
        idle ->
            %% TODO: parse HTTP error statuses
            ?LOG_DEBUG("~p received data while idle: ~p", [self(), Data]),
            error(internal)
    end.

clock_recv(State) ->
    State#state{lastrecv=system_time()}.

next_request(#state{status=idle} = State0) ->
    case request_sender:next_ready() of
        null -> loop(State0);
        {DataPid,Ref,Head} = Req ->
            ?DBG("next_request", {req,Ref}),
            relay_request(DataPid, Ref, Head, State0),
            case head_begin(clock_recv(State0#state{req=Req})) of
                {error,Reason} -> exit(Reason);
                {ok,State} ->
                    % TODO: relay multiple requests at a time
                    % (needs a queue or something to track request
                    % refs)
                    %{noreply, State, {continue, next_request}}
                    loop(State)
            end
    end;

next_request(State) ->
    loop(State).

close_request(State0) ->
    case State0#state.req of
        null ->
            %% should not happen
            error(internal);
        {_,Ref,_} ->
            request_manager:close(Ref),
            case {State0#state.close, State0#state.ssl} of
                {true,false} ->
                    %% The last response requested that we close the connection.
                    ok = gen_tcp:shutdown(State0#state.socket, write),
                    loop(State0);
                {true,true} ->
                    %% The last response requested that we close the connection.
                    ok = ssl:shutdown(State0#state.socket, write),
                    loop(State0);
                {false,_} ->
                    State = State0#state{status=idle, rstate=null, req=null},
                    next_request(State)
            end
    end.

heartbeat(State) ->
    Delta = convert_time_unit(system_time() - State#state.lastrecv,
                              native, millisecond),
    if
        State#state.status =:= idle ->
            loop(State);
        Delta > ?REQUEST_TIMEOUT ->
            exit(timeout);
        true ->
            loop(State)
    end.

%%% parsing/receiving HTTP message portions
%%%

head_begin(State) ->
    HReader = pimsg:head_reader(),
    head_data(?EMPTY, State#state{status=head, rstate=HReader}).

head_data(?EMPTY, State) -> {ok,State};
head_data(Bin, #state{rstate=RState0} = State) ->
    case pimsg:head_reader(RState0, Bin) of
        {error,Reason} ->
            exit(Reason);
        {continue,RState} ->
            loop(State#state{rstate=RState});
        {done,StatusLine,Headers,Rest} ->
            head_end(StatusLine, Headers, Rest, State)
            %case phttp:status_split(StatusLine) of
            %    {error,Reason} -> {stop,Reason,State};
            %    {ok,Status} -> head_end(Status, Headers, Rest, State)
            %end
    end.

head_end(StatusLn, Headers, Rest, State) ->
    {Pid,Ref,ReqHead} = State#state.req,
    Method = ReqHead#head.method,
    case pimsg:response_length(Method, StatusLn, Headers) of
        {ok,0} ->
            ResHead = #head{method=Method, line=StatusLn,
                            headers=Headers, bodylen=0},
            inbound:respond(Pid, Ref, ResHead),
            %% XXX: I'm not sure if sending ?EMPTY is necessary?
            inbound:respond(Pid, Ref, {body,?EMPTY}),
            close_request(State#state{rstate=null});
        {ok,BodyLen} ->
            ResHead = #head{method=Method, line=StatusLn,
                            headers=Headers, bodylen=BodyLen},
            inbound:respond(Pid, Ref, ResHead),
            body_begin(Rest, BodyLen, State);
        {error,missing_length} ->
            exit({missing_length,StatusLn,Headers})
    end.

body_begin(Bin, BodyLen, State) ->
    ?DBG("body_begin", {bodylen,BodyLen}),
    RState = pimsg:body_reader(BodyLen),
    body_data(Bin, State#state{status=body, rstate=RState}).

body_data(?EMPTY, State) ->
    loop(State);

body_data(Data, #state{rstate=RState0} = State) ->
    %%io:format("*****~s*****~n", [Data]),
    case pimsg:body_reader(RState0, Data) of
        {error,Reason} ->
            exit(Reason);
        {continue,?EMPTY,RState} ->
            %% Avoids sending messages about nothing.
            ?DBG("body_data", {continue,?EMPTY,RState}),
            loop(State#state{rstate=RState});
        {continue,Scanned,RState} ->
            ?DBG("body_data", {continue,RState}),
            {DataPid,Ref,_} = State#state.req,
            inbound:respond(DataPid, Ref, {body,Scanned}),
            loop(State#state{rstate=RState});
        {done,Scanned,Rest} ->
            ?DBG("body_data", done),
            {DataPid,Ref,_} = State#state.req,
            inbound:respond(DataPid, Ref, {body,Scanned}),
            %% There should be no extra bytes after the end of the body.
            %% XXX: Because there is no request pipelining ... yet.
            case Rest of
                ?EMPTY ->
                    close_request(State#state{status=idle, rstate=null});
                _ ->
                    exit({body_remains,Rest})
            end
    end.

%%% sending data over sockets
%%%

send(Data, #state{socket=Sock, ssl=false}) ->
    case gen_tcp:send(Sock, Data) of
        {error,Reason} -> exit(Reason);
        ok -> ok
    end;

send(Data, #state{socket=Sock, ssl=true}) ->
    case ssl:send(Sock, Data) of
        {error,Reason} -> exit(Reason);
        ok -> ok
    end.

send_lines([], _) ->
    ok;

send_lines([X|L], State) ->
    send(X, State),
    send(<<?CRLF>>, State),
    send_lines(L, State).

relay_request(DataPid, Ref, Head, State) ->
    #head{line=Line, headers=Headers} = Head,
    send_lines([Line, fieldlist:to_binary(Headers)], State),
    case Head#head.bodylen of
        0 -> ok;
        _ -> relay_body_out(DataPid, Ref, State)
    end.

relay_body_out(DataPid, Ref, State) ->
    case inbound:request_body(DataPid, Ref) of
        {error,Reason} ->
            error(Reason);
        {some, []} ->
            relay_body_out(DataPid, Ref, State);
        {some, Io} ->
            send(Io, State),
            relay_body_out(DataPid, Ref, State);
        done ->
            ok
    end.
