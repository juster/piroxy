-module(outbound).
-behavior(gen_server).

-include("pimsg.hrl").
-include_lib("kernel/include/logger.hrl").

-record(outstate, {state, socket, ssl, rstate=null, close=false, req=null,
                   buffer=?EMPTY}).

-export([connect/3, new_request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2,
         terminate/2]).

connect(http, Host, Port) ->
    gen_server:start_link(?MODULE, [Host, Port, false], []);

connect(https, Host, Port) ->
    gen_server:start_link(?MODULE, [Host, Port, true], []).

%% notify the outbound Pid that a new request is ready for it to send/recv
new_request(Pid) ->
    gen_server:cast(Pid, new_request).

%%% behavior functions

init([Host, Port, false]) ->
    case gen_tcp:connect(Host, Port, [binary, {packet, 0}]) of
        {ok, Sock} ->
            {ok, #outstate{state=idle, socket=Sock, ssl=false, buffer=?EMPTY}};
        {error, Reason} ->
            error(Reason)
    end;

init([Host, Port, true]) ->
    case ssl:connect(Host, Port, [binary, {packet, 0}]) of
        {ok, Sock} ->
            {ok, #outstate{state=idle, socket=Sock, ssl=true, buffer=?EMPTY}};
        {error, Reason} ->
            error(Reason)
    end.

handle_call(_Msg, _From, _State) ->
    error(unimplemented).

handle_cast(new_request, State) ->
    {noreply, State, {continue, next_request}}.

%% continuation is used after a request is finished and when a
%% new_request notification is received (and we are idle)
handle_continue(next_request, #outstate{state=idle} = State0) ->
    case request_manager:next_request() of
        null -> {noreply,State0};
        {DataPid,Ref,Head} = Req ->
            case relay_request(DataPid, Ref, Head, State0) of
                {error,Reason} -> {stop,Reason,State0};
                ok ->
                    case head_begin(State0#outstate{req=Req}) of
                        {error,Reason} -> {stop,Reason,State0};
                        {ok,State} ->
                            % TODO: relay multiple requests at a time
                            % (needs a queue or something to track request
                            % refs)
                            %{noreply, State, {continue, next_request}}
                            {noreply,State}
                    end
            end
    end;

handle_continue(next_request, State) ->
    %% If we are not idle, wait until we are before sending the next request.
    {noreply, State};

handle_continue(close_request, State0) ->
    case State0#outstate.req of
        null ->
            {stop, no_active_request, State0};
        {_,Ref,_} ->
            request_manager:close_request(Ref),
            case State0#outstate.close of
                true ->
                    %% The last response requested that we close the connection.
                    {stop, normal, State0};
                false ->
                    State = State0#outstate{state=idle, rstate=null, req=null},
                    {noreply, State, {continue, next_request}}
            end
    end.

handle_info({tcp_closed, _}, State) ->
    {stop, normal, State};

handle_info({tcp_error, Reason}, State) ->
    {stop, Reason, State};

handle_info({tcp, _Sock, Data}, #outstate{state=head} = State) ->
    head_data(Data, State);

handle_info({tcp, _Sock, Data}, #outstate{state=body} = State) ->
    body_data(Data, State);

handle_info({tcp, _Sock, Bin}, State) ->
    %% TODO: shutdown socket?
    {stop, {unexpected_recv, Bin}, State};

handle_info({ssl_closed, _}, State) ->
    {stop, normal, State#outstate{socket=null}};

handle_info({ssl_error, Reason}, State) ->
    {stop, Reason, State};

handle_info({ssl, _Sock, Data}, State = #outstate{state=head}) ->
    head_data(Data, State);

handle_info({ssl, _Sock, Data}, State = #outstate{state=body}) ->
    body_data(Data, State);

handle_info({ssl, _Sock, Bin}, State) ->
    %% TODO: shutdown socket?
    {stop, {unexpected_recv, Bin}, State}.

terminate(_Reason, #outstate{socket=null}) ->
    ok;

terminate(_Reason, #outstate{socket=Sock, ssl=false}) ->
    ok = gen_tcp:close(Sock);

terminate(_Reason, #outstate{socket=Sock, ssl=true}) ->
    ok = ssl:close(Sock, infinity).

%%% receiving states

head_begin(State) ->
    HReader = pimsg:head_reader(),
    head_data(State#outstate.buffer,
              State#outstate{state=head, rstate=HReader}).

head_data(?EMPTY, State) -> {ok,State};
head_data(Bin, #outstate{rstate=RState0} = State) ->
    case pimsg:head_reader(RState0, Bin) of
        {error,Reason} ->
            {stop,Reason,State};
        {continue, RState} ->
            {noreply, State#outstate{rstate=RState}};
        {done, StatusLine, Headers, Rest} ->
            head_end(StatusLine, Headers, Rest, State)
            %case phttp:status_split(StatusLine) of
            %    {error,Reason} -> {stop,Reason,State};
            %    {ok,Status} -> head_end(Status, Headers, Rest, State)
            %end
    end.

head_end(StatusLn, Headers, Rest, State) ->
    {Pid,Ref,ReqHead} = State#outstate.req,
    Method = ReqHead#head.method,
    case pimsg:response_length(Method, StatusLn, Headers) of
        {ok,0} ->
            ResHead = #head{method=Method, line=StatusLn,
                            headers=Headers, bodylen=0},
            inbound:respond(Pid, Ref, {head,ResHead}),
            inbound:respond(Pid, Ref, {body,?EMPTY}),
            {noreply, State#outstate{rstate=null}, {continue,close_request}};
        {ok,BodyLen} ->
            ResHead = #head{method=Method, line=StatusLn,
                            headers=Headers, bodylen=BodyLen},
            inbound:respond(Pid, Ref, {head,ResHead}),
            body_begin(Rest, BodyLen, State);
        {error,missing_length} ->
            {stop, {missing_length,StatusLn,Headers}, State}
    end.

body_begin(Bin, BodyLen, State) ->
    RState = pimsg:body_reader(BodyLen),
    body_data(Bin, State#outstate{state=body, rstate=RState}).

body_data(?EMPTY, State) ->
    {noreply, State};

body_data(Data, #outstate{rstate=RState0} = State) ->
    case pimsg:body_reader(RState0, Data) of
        {error,Reason} ->
            {stop,Reason,State};
        {continue,?EMPTY,RState} ->
            %% Avoids sending messages about nothing.
            {noreply, State#outstate{rstate=RState}};
        {continue,Scanned,RState} ->
            {DataPid,Ref,_} = State#outstate.req,
            inbound:respond(DataPid, Ref, {body,Scanned}),
            {noreply, State#outstate{rstate=RState}};
        {done,Scanned,Rest} ->
            {DataPid,Ref,_} = State#outstate.req,
            inbound:respond(DataPid, Ref, {body,Scanned}),
            %% There should be no extra bytes after the end of the body.
            %% XXX: Because there is no request pipelining ... yet.
            case Rest of
                ?EMPTY ->
                    {noreply, State#outstate{state=idle, rstate=null},
                     {continue,close_request}};
                _ ->
                    {stop, {body_remains,Rest}, State}
            end
    end.

%%% request helper functions

send(Data, #outstate{socket=Sock, ssl=false}) ->
    gen_tcp:send(Sock, Data);

send(Data, #outstate{socket=Sock, ssl=true}) ->
    ssl:send(Sock, Data).

relay_request(DataPid, Ref, Head, State) ->
    #head{line=Line, headers=Headers} = Head,
    case send_lines([Line, fieldlist:to_binary(Headers)], State) of
        {error, Reason} -> {error, Reason};
        ok ->
            case Head#head.bodylen of
                0 -> ok;
                _ -> relay_body_out(DataPid, Ref, State)
            end
    end.

send_lines([], _) ->
    ok;

send_lines([X|L], State) ->
    case send(X, State) of
        {error,_} = Err -> Err;
        ok ->
            case send(<<?CRLF>>, State) of
                {error,_} = Err -> Err;
                ok -> send_lines(L, State)
            end
    end.

relay_body_out(DataPid, Ref, State) ->
    case inbound:request_body(DataPid, Ref) of
        {error, Reason} ->
            {error, Reason};
        {some, []} ->
            relay_body_out(DataPid, Ref, State);
        {some, Io} ->
            case send(Io, State) of
                {error, Reason} ->
                    {error, Reason};
                ok ->
                    relay_body_out(DataPid, Ref, State)
            end;
        {last, []} ->
            ok;
        {last, Io} ->
            send(Io, State)
    end.
