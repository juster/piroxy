%%% inbound_stream
%%% Streams requests and responses, one after another, allowing for pipelining
%%% requests to an outbound process. The responses to these requests are cached
%%% and streamed back to the (1) process that made the requests.

%%% client --{new,HostInfo,Head}--> inbound_stream
%%%     inbound_stream --{new,HostInfo,head}--> request_manager
%%% client --{body,Body}--> inbound_stream (0*)
%%% client --{body_finish}--> inbound_stream
%%%
%%%     inbound_stream <--request_body--  outbound
%%%     inbound_stream --{body,Body}-->   outbound
%%%
%%%     inbound_stream <--{respond,{head,...}}-- outbound
%%% client <--{respond,{head,...} inbound_stream
%%%     inbound_stream <--{respond,close}-- outbound
%%% client <--{respond,close}-- inbound_stream
%%%

-module(inbound_stream).
-behavior(gen_server).
-include("phttp.hrl").

-define(MAX_ACTIVE, 128).

%%-record(session, {ref, chunks=[], msgs=[], reqdone=false, resdone=false}).
-record(state, {pid, reqQ=[], respQ=[]}).

-import(lists, [foreach/2, reverse/1, reverse/2]).
-export([start_link/0, receive_body/2, reflect/2, disconnect/1]).
-export([init/1, terminate/2, handle_cast/2, handle_call/3]).

%%% external interface

start_link() ->
    gen_server:start_link(?MODULE, [self()], []).

request_body(ServerRef, Chunk) ->
    gen_server:cast(ServerRef, {request_body,Chunk}).

request_end(ServerRef) ->
    gen_server:cast(ServerRef, request_end).

reflect(ServerRef, Messages) ->
    gen_server:cast(ServerRef, {reflect,Messages}).

%% end the connection but only after pending responses in the
%% pipeline are relayed
disconnect(ServerRef) ->
    gen_server:cast(ServerRef, disconnect).

%%% behavior callbacks

init([Pid]) ->
    {ok, #state{pid=Pid}}.

terminate(_Reason, S) ->
    foreach(fun ({Ref,_}) ->
                    request_manager:cancel_request(Ref)
            end, S#state.respQ).

stream_response(S) ->
    %% queues must not be empty
    case {hd(S#state.reqQ), hd(S#state.respQ)} of
        {{Ref1,_} {Ref2,_}} ->
            %% references should be identical
            error(internal, S);
        {{Ref,done}, {Ref,L}} ->
            case L of
                [] -> S;
                [done|L2] ->
                    replay(reverse(L2), S)
                    stream_response(S#state{reqQ=tl(S#state.reqQ),
                                            respQ=tl(S#state.respQ)});
                L2 ->
                    replay(reverse(L2), S),
                    S#state{respQ=[{Ref,[]}|tl(S#state.respQ)]}
                _ -> S
            end;
        _ -> S
    end.

handle_call({new,HostInfo,Head}, _From, S0) ->
    Ref = request_manager:new_request(HostInfo, Head),
    Q1 = S0#state.reqQ,
    Q2 = S0#state.respQ,
    S = S0#state{reqQ=Q1 ++ [{Ref,empty}],
                 respQ=Q2 ++ [{Ref,empty}]},
    {reply, Ref, S};

%% called by outgoing process to retrieve the request body
handle_call({request_body,Ref}, From, S) ->
    case queue_find(Ref, S#state.reqQ) of
        not_found ->
            %% {Ref,...} entry should have been added to the
            %% queue.
            {reply,{error,unknown_ref},S};
        {found,empty,Q1,Q2} ->
            %% block the call if the request body has not yet been sent
            %% by the client
            Q = reverse(Q1, [{Ref,{blocked,From}}|Q2]),
            {noreply,S#state{reqQ=Q}};
        {found,{last,_}=T,Q1,Q2} ->
            %% mark the request as done. if possible, stream the response
            %% back to the client.
            Q = reverse(Q1, [{Ref,done}|Q2]),
            S2 = stream_response(S#state{reqQ=Q}),
            {reply,T,S2};
        {found,{some,_}=T,Q1,Q2} ->
            %% reset the value to empty
            Q = reverse(Q1, [{Ref,empty}|Q2]),
            {reply,T,S#state{reqQ=Q}};
        {found,{blocked,From},Q1,Q2} ->
            %% we cannot block again because we are already blocked
            %% (why is there another request_body for the same Ref?)
            {reply,{error,already_blocked},S}
    end.

%% called by client to append to request body
handle_cast({request_stream,Chunk}, S) ->
    %% should be the next in the queue
    Q = case S#state.reqQ of
            %% Queue should not be empty!
            [] -> {stop,internal_error,S};
            [{Ref,X}|Q0] ->
                Z = case X of
                        empty ->
                            {some,Chunk};
                        {some,Y} ->
                            {some,[Chunk|Y]};
                        {last,_} ->
                            error(internal);
                        {blocked,From} ->
                            gen_server:reply(From, {some,Chunk}),
                            empty;
                    end,
                [{Ref,Z}|Q0]
        end,
    S#state{reqQ=Q}.

handle_cast(request_end, S) ->
    Q = case S#state.reqQ of
            %% Queue should not be empty!
            [] ->
                {stop,internal_error,S};
            [{Ref,empty}|Q0] ->
                [{Ref,{last,?EMPTY}}|Q0];
            [{Ref,{some,Y}}|Q0] ->
                [{Ref,{last,Y}}|Q0];
            [{Ref,{last,_}=T}|Q0] ->
                [{Ref,T}|Q0];
            [{Ref,{blocked,From}}|Q0] ->
                %% Outbound is already blocked, waiting...
                %% Gives empty reply and removes the request from the queue.
                gen_server:reply(From, {last,?EMPTY}),
                Q0
        end,
    {noreply, S#state{reqQ = Q}}.

handle_cast({close,Ref}, S0) ->
    case S0#state.respQ of
        [{Ref,_}|Q0] ->
    case is_active_ref(Ref, S0) of
        false ->
            true = ets:update_element(S0#state.tab, Ref,
                                      {#session.respdone,true}),
            {noreply,S0};
        true ->
            Tab = S0#state.tab,
            [Session] = ets:lookup(Tab, Ref),
            case Session#session.reqdone of
                false ->
                    %% We have a problem: the response finished before the request.
                    {stop, internal_error, S0};
                true ->
                    case Session#session.chunks of
                        [] ->
                            S = close_session(S0),
                            {noreply,S};
                        L ->


            end
    end;

handle_cast({reset,Ref}, S) ->
    case is_active_ref(Ref, S) of
        false ->
            %% overwrite the old session with a fresh one
            ets:insert(S#state.tab, #session{ref=Ref})
            {noreply,S};
        true ->
            relay(reset, S),
            {noreply,S}
    end;

handle_cast({respond,Ref,{head,_,_} = Head}, S) ->
    case is_active_ref(Ref, S) of
        false ->
            true = ets:update_element(S#state.tab, Ref, [{#session.cache,[Head]}]),
            {noreply,S};
        true ->
            %% no need to save if it is currently active
            relay(Head, S),
            {noreply,S}
    end;

handle_cast({respond,Ref,{body,_} = Body}, S) ->
    case is_active_ref(Ref, S) of
        false ->
            Tab = S#state.tab,
            [Ses] = ets:lookup(Ref, Tab),
            case Ses#session.cache of
                undefined ->
                    %% we should not receive the body of the response before
                    %% the head of the response
                    {stop,body_before_head,S};
                L0 ->
                    L = [Body|L0],
                    true = ets:update_element(Tab, Ref, {#session.cache,L}),
                    {noreply,S}
            end;
        true ->
            %% no need to save if it is currently active
            relay(Body, S),
            {noreply,S}
    end;

handle_cast({reflect,Responds},S0) ->
    Session = #session{ref=make_ref(), cache=Responds, closed=true},
    {noreply, push_session(Session, S0)};

handle_cast(disconnect,S0) ->
    ?DBG("disconnect", {todo_empty,todo_empty(S0)}),
    S = S0#state{disconnect=true},
    case cbuf:is_empty(S) of
        true -> S#state.pid ! disconnect;
        false -> ok
    end,
    {noreply,S}.

-compile(respond, {inline,2}).
respond(Msg, S) ->
    S#state.pid ! {respond,Msg}.

is_active_ref(Ref, S) ->
    case circbuff:top(S#state.queue) of
        empty -> empty;
        {ok,Ref} -> true;
        _ -> false
    end.

send_if_active(Ref, Msg, S) ->
    case is_active_ref(Ref, S) of
        %% should always have at least 1 ref when this is called
        empty -> error(internal);
        false -> pending;
        true ->
            S#state.pid ! Msg,
            active
    end.

%% Circular buffer queue functions
%% readi <= writei ... readi is trying to catch up to writei
%% readi > writei ... we are caught up and are currently idle
%% readi is the *next* session to relay
%% writei is the *last* session we created
%% if readi >= writei then there are no pending sessions in the todo list
%% (but there may be one currently active)
%% if readi == writei then there is an active session in the todo list

push_session(Session, S0) ->
    true = ets:insert(S0#state.tab, Session),
    Queue0 = S0#state.queue,
    {ok,Queue} = cbuf:push(Queue0, Session#session.ref),
    S = S0#state{queue=Queue},

    %% If the queue was empty before we pushed our new session to it, then
    %% immediately go to work on this new session.
    case cbuf:is_empty(Queue0) of
        true -> next_todo(S);
        false -> S
    end.

close_session(S) ->
    {ok,Ref} = cbuf:top(S#state.queue),
    respond(close, S),
    ets:delete(S#state.tab, Ref),
    {ok,Q} = cbuf:pop(S#state.queue), %should not be empty
    next_session(S#state{queue=Q}).

next_session(S) ->
    Q0 = S#state.queue,
    case cbuf:top(Q0) of
        empty ->
            %% XXX: can't remember what disconnect is for
            case S#state.disconnect of
                true -> S#state.pid ! disconnect,
                false -> ok
            end,
            S; % stay idle
        {ok,Ref} ->
            Tab = S#state.tab,
            [Req] = ets:lookup(Tab, Ref),
            Responds = reverse(Req#session.cache),
            ets:update_element(Tab, Ref, {#session.cache,[]}),
            replay(Responds, S),
            case Req#session.closed of
                false ->
                    S;
                true ->
                    %% close the session
                    foreach(fun (Res) -> respond(Res, S) end, Responds),
                    {ok,Q} = cbuf:pop(Q),
                    ets:delete(Tab, Ref),
                    next_session(S#state{refs=Q})
            end
    end.

-compile(inline, {fifo_push,2}).
fifo_push(X, L) ->
    reverse([X|reverse(L)])).

find(X, L1) -> queue_find(X, L1, []).
find(X, [{X,Y}|L1], L2) -> {found,Y,L2,L1}; % reverse(L2, [T|L1]) rebuilds
find(X, [Z|L1], L2) -> queue_find(X, L1, [Z|L2]).
find(X, [], L2) -> not_found.
