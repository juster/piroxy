-module(outbound).
-behavior(gen_server).

-include("phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-record(outstate, {state, socket, hstate, buffer=?EMPTY, close=false, req=null}).

-export([start_link/2, new_request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2, handle_info/2,
         terminate/2]).

start_link(Host, Port) ->
    gen_server:start_link(?MODULE, [Host, Port], []).

%% notify the outbound Pid that a new request is ready for it to send/recv
new_request(Pid) ->
    gen_server:cast(Pid, new_request).

%%% behavior functions

init([Host, Port]) ->
    case gen_tcp:connect(Host, Port, [binary, {packet, 0}]) of
        {ok, Sock} ->
            {ok, #outstate{state=idle, socket=Sock, buffer=?EMPTY}};
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
    {stop, {unexpected_recv, Bin}, State}.

terminate(_Reason, State) ->
    gen_tcp:close(State#outstate.socket).

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
    {ok, BodyLength} = phttp:body_length(Method, Status, Headers),
    body_begin(Bin, phttp:body_reader(BodyLength), State).

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
            {DataPid,Ref,_} = State#outstate.req,
            inbound:respond(DataPid, Ref, {body, Bin1}),
            {noreply, State#outstate{state=idle, buffer=Bin2}, {continue, close_request}}
    end.

%%% request helper functions

send_request(DataPid, Ref, {Method, Url, Headers}, State) ->
    Sock = State#outstate.socket,
    Lines = [<<Method/binary, " ", Url/binary, " ", ?HTTP11>>,
             fieldlist:to_binary(Headers)],
    case send_lines(Sock, Lines) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            relay_body_out(DataPid, Ref, Sock)
    end.

send_lines(_, []) ->
    ok;

send_lines(Sock, [X|L]) ->
    %%io:format("DBG: send_lines X=~p~n", [X]),
    case gen_tcp:send(Sock, X) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            case gen_tcp:send(Sock, <<?CRLF>>) of
                {error, Reason} ->
                    {error, Reason};
                ok ->
                    send_lines(Sock, L)
            end
    end.

relay_body_out(DataPid, Ref, Sock) ->
    case inbound:request(DataPid, Ref, body) of
        {error, Reason} ->
            {error, Reason};
        {more, ?EMPTY} ->
            relay_body_out(DataPid, Ref, Sock);
        {more, Bin} ->
            case gen_tcp:send(Sock, Bin) of
                {error, Reason} ->
                    {error, Reason};
                ok ->
                    relay_body_out(DataPid, Ref, Sock)
            end;
        {last, ?EMPTY} ->
            ok;
        {last, Bin} ->
            gen_tcp:send(Sock, Bin)
    end.
