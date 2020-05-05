-module(outbound).
-behavior(gen_server).

-include("phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-record(outstate, {state, socket, ssl, hstate, buffer=?EMPTY, close=false, req=null}).

-export([connect_http/2, connect_https/2, new_request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2,
         terminate/2]).

connect_http(Host, Port) ->
    gen_server:start_link(?MODULE, [Host, Port, false], [debug,{[trace]}]).

connect_https(Host, Port) ->
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
handle_continue(next_request, #outstate{state=idle} = State) ->
    case request_manager:next_request() of
        null ->
            {noreply, State};
        {DataPid, Ref, Request} = Req ->
            case send_request(DataPid, Ref, Request, State) of
                {error, Reason} ->
                    {stop, Reason, State};
                ok ->
                    recv_begin(State#outstate{req=Req})
            end
    end;

handle_continue(next_request, State) ->
    %% If we are not idle, wait until we are before sending the next request.
    {noreply, State};

handle_continue(close_request, State) ->
    case State#outstate.req of
        null ->
            {stop, no_active_request, State};
        {_,Ref,_} ->
            request_manager:close_request(Ref),
            case State#outstate.close of
                true ->
                    %% The last response requested that we close the connection.
                    {stop, normal, State};
                false ->
                    {noreply, State#outstate{state=idle, hstate=null, req=null},
                     {continue, next_request}}
            end
    end.

handle_info({tcp_closed, _}, State) ->
    {stop, normal, State};

handle_info({tcp_error, Reason}, State) ->
    {stop, Reason, State};

handle_info({tcp, _Sock, Data}, State = #outstate{state=head}) ->
    head_data(Data, State);

handle_info({tcp, _Sock, Data}, State = #outstate{state=body}) ->
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

recv_begin(State) ->
    HState = phttp:response_head(),
    head_data(State#outstate.buffer,
              State#outstate{state=head, hstate=HState, buffer=?EMPTY}).

head_data(?EMPTY, State) ->
    {noreply, State};

head_data(Data, State = #outstate{hstate=HState0, buffer=Buf}) ->
    case phttp:response_head(Buf, Data, HState0) of
        {error, Reason} ->
            {stop, Reason};
        {skip, Bin, HState} ->
            {noreply, State#outstate{hstate=HState, buffer=Bin}};
        {redo, Bin, HState} ->
            head_data(Bin, State#outstate{hstate=HState, buffer=?EMPTY});
        {last, Bin, Status, Headers} ->
            head_finish(Bin, Status, Headers, State)
    end.

head_finish(Bin, Status, Headers, State) ->
    {DataPid, Ref, {Method,_,_}} = State#outstate.req,
    inbound:respond(DataPid, Ref, {head, Status, Headers}),
    case phttp:body_length(Method, Status, Headers) of
        {ok, BodyLength} ->
            body_begin(Bin, phttp:body_reader(BodyLength), State);
        {error, missing_length} ->
            {stop, {error, missing_length, Status, Headers}, State}
    end.

body_begin(Bin, HState, State) ->
    body_data(Bin, State#outstate{state=body, hstate=HState, buffer=?EMPTY}).

body_data(?EMPTY, State) ->
    {noreply, State};

body_data(Data, State = #outstate{hstate=HState0, buffer=Buf}) ->
    case phttp:body_next(Buf, Data, HState0) of
        {error, Reason} ->
            {stop, Reason};
        {wait, ?EMPTY, Bin2, HState} ->
            {noreply, State#outstate{hstate=HState, buffer=Bin2}};
        {wait, Bin1, Bin2, HState} ->
            {DataPid,Ref,_} = State#outstate.req,
            inbound:respond(DataPid, Ref, {body, Bin1}),
            {noreply, State#outstate{hstate=HState, buffer=Bin2}};
        {redo, ?EMPTY, Bin2, Bin3, HState} ->
            %% Avoids sending messages about nothing.
            body_data(Bin3, State#outstate{hstate=HState, buffer=Bin2});
        {redo, Bin1, Bin2, Bin3, HState} ->
            {DataPid,Ref,_} = State#outstate.req,
            inbound:respond(DataPid, Ref, {body, Bin1}),
            body_data(Bin3, State#outstate{hstate=HState, buffer=Bin2});
        {last, Bin1, Bin2} ->
            io:format("*DBG* last -- ~p -- ~p~n", [Bin1, Bin2]),
            {DataPid,Ref,_} = State#outstate.req,
            inbound:respond(DataPid, Ref, {body, Bin1}),
            {noreply, State#outstate{state=idle, buffer=Bin2}, {continue, close_request}}
    end.

%%% request helper functions

send(Data, #outstate{socket=Sock, ssl=false}) ->
    gen_tcp:send(Sock, Data);

send(Data, #outstate{socket=Sock, ssl=true}) ->
    ssl:send(Sock, Data).

send_request(DataPid, Ref, {Method, Url, Headers}, State) ->
    Lines = [<<Method/binary, " ", Url/binary, " ", ?HTTP11>>,
             fieldlist:to_binary(Headers)],
    case send_lines(Lines, State) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            relay_body_out(DataPid, Ref, State)
    end.

send_lines([], _) ->
    ok;

send_lines([X|L], State) ->
    %%io:format("DBG: send_lines X=~p~n", [X]),
    case send(X, State) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            case send(<<?CRLF>>, State) of
                {error, Reason} ->
                    {error, Reason};
                ok ->
                    send_lines(L, State)
            end
    end.

relay_body_out(DataPid, Ref, State) ->
    case inbound:request(DataPid, Ref, body) of
        {error, Reason} ->
            {error, Reason};
        {more, ?EMPTY} ->
            relay_body_out(DataPid, Ref, State);
        {more, Bin} ->
            case send(Bin, State) of
                {error, Reason} ->
                    {error, Reason};
                ok ->
                    relay_body_out(DataPid, Ref, State)
            end;
        {last, ?EMPTY} ->
            ok;
        {last, Bin} ->
            send(Bin, State)
    end.
