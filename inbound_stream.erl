%%% inbound_stream
%%% Streams requests and responses, one after another, allowing for pipelining
%%% requests to an outbound process. The responses to these requests are cached
%%% and streamed back to the (1) process that made the requests.

-module(inbound_stream).
-behavior(gen_server).
-include("pimsg.hrl").

-define(MAX_ACTIVE, 128).
-record(session, {ref, reqbody=[], cache, closed=false}).
-record(state, {pid, readi=0, writei=(-1), refs, tab, disconnect=false}).

-import(lists, [foreach/2, reverse/1]).
-export([start_link/0, receive_body/2, reflect/2, disconnect/1]).
-export([init/1, terminate/2, handle_cast/2, handle_call/3]).

%%% external interface

start_link() ->
    gen_server:start_link(?MODULE, [self()], []).

receive_body(ServerRef, Chunk) ->
    gen_server:cast(ServerRef, {append_body,Chunk}).

reflect(ServerRef, Messages) ->
    gen_server:cast(ServerRef, {reflect,Messages}).

%% end the connection but only after pending responses in the
%% pipeline are relayed
disconnect(ServerRef) ->
    gen_server:cast(ServerRef, disconnect).

%%% behavior callbacks

init([Pid]) ->
    Buf = array:new([{size,?MAX_ACTIVE}, fixed]),
    Tab = ets:new(sessions, [set,private,{keypos,#session.ref}]),
    {ok, #state{pid=Pid, refs=Buf, tab=Tab}}.

terminate(_Reason, State) ->
    Tab = State#state.tab,
    cancel_requests(ets:first(Tab), Tab),
    ets:delete(Tab).

cancel_requests('$end_of_table', _) -> ok;
cancel_requests(Ref, Tab) ->
    request_manager:cancel_request(Ref),
    cancel_requests(ets:next(Tab, Ref), Tab).

handle_call({new,HostInfo,Head}, _From, State0) ->
    case State0#state.disconnect of
        true -> {reply,disconnected,State0};
        false ->
            case request_manager:new_request(HostInfo, Head) of
                {error,Reason} ->
                    {stop, Reason, State0};
                {ok,Ref} ->
                    State = push_session(#session{ref=Ref}, State0),
                    {reply, Ref, State}
            end
    end;

%% called by outgoing process to retrieve the request body
handle_call({request_body,Ref}, _From, State) ->
    Tab = State#state.tab,
    [Res] = ets:lookup(Tab, Ref),
    Body = reverse(Res#session.cache),
    case Res#session.closed of
        true ->
            {reply, {last,Body}, State};
        false ->
            ets:update(Tab, Ref, {#session.cache,[]}),
            {reply, {some,Body}, State}
    end.

handle_cast({append_body,Chunk}, State) ->
    Tab = State#state.tab,
    Ref = input_ref(State),
    [Res] = ets:lookup(Tab, Ref),
    Cache = Res#session.cache,
    ets:update(Tab, Ref, {#session.cache,[Chunk|Cache]}),
    {noreply, State};

handle_cast({close,Ref}, State) ->
    case send_if_active(Ref, close, State) of
        not_found ->
            {stop,{unknown_ref,Ref},State};
        pending ->
            ets:update(State#state.tab, Ref, {#session.closed,true}),
            {noreply,State};
        active ->
            ets:delete(State#state.tab, Ref),
            {noreply,next_todo(State)}
    end;

handle_cast({reset,Ref}, State) ->
    case send_if_active(Ref, reset, State) of
        not_found ->
            {stop,{unknown_ref,Ref},State};
        pending ->
            ets:update(State#state.tab, Ref, [{#session.closed,false},
                                              {#session.cache,undefined}]),
            {noreply,State};
        active ->
            {noreply,State}
    end;

handle_cast({respond,Ref,{head,_,_} = Head}, State) ->
    case send_if_active(Ref, Head, State) of
        not_found ->
            {stop,{unknown_ref,Ref},State};
        pending ->
            ets:update(State#state.tab, Ref, [{#session.cache,[Head]}]),
            {noreply,State};
        active ->
            %% no need to save if it is currently active
            {noreply,State}
    end;

handle_cast({respond,Ref,{body,_} = Body}, State) ->
    case send_if_active(Ref, Body, State) of
        not_found ->
            {stop,{unknown_ref,Ref},State};
        pending ->
            Tab = State#state.tab,
            [Ses] = ets:lookup(Ref, Tab),
            case Ses#session.cache of
                undefined ->
                    %% we should not receive the body of the response before
                    %% the head of the response
                    exit(body_before_head);
                L0 ->
                    L = [Body|L0],
                    ets:update(Tab, Ref, {#session.cache,L}),
                    {noreply,State}
            end;
        active ->
            %% no need to save if it is currently active
            {noreply,State}
    end;

handle_cast({reflect,Responds},State0) ->
    Session = #session{ref=make_ref(), cache=Responds, closed=true},
    {noreply, push_session(Session, State0)};

handle_cast(disconnect,State0) ->
    ?DBG("disconnect", {todo_empty,todo_empty(State0)}),
    State = State0#state{disconnect=true},
    case is_idle(State) of
        true -> State#state.pid ! disconnect;
        false -> ok
    end,
    {noreply, State}.

is_idle(State) ->
    State#state.readi > State#state.writei.

todo_empty(State) ->
    State#state.readi >= State#state.writei.

send_if_active(Ref, Msg, State) ->
    case is_active(Ref, State) of
        not_found -> not_found;
        false -> pending;
        true ->
            State#state.pid ! Msg,
            active
    end.

is_active(Ref, State) ->
    case todo_empty(State) of
        true -> not_found; % should normally not be empty
        false ->
            case output_ref(State) of
                Ref -> true;
                _ -> false
            end
    end.

output_ref(State) ->
    array:get(State#state.readi rem ?MAX_ACTIVE, State#state.refs).

input_ref(State) ->
    array:get(State#state.writei rem ?MAX_ACTIVE, State#state.refs).

%% Circular buffer queue functions
%% readi <= writei ... readi is trying to catch up to writei
%% readi > writei ... we are caught up and are currently idle
%% readi is the *next* session to relay
%% writei is the *last* session we created
%% if readi >= writei then there are no pending sessions in the todo list
%% (but there may be one currently active)
%% if readi == writei then there is an active session in the todo list

push_session(Session, State0) ->
    ?DBG("push_session", {session,Session,readi,State0#state.readi,writei,State0#state.writei}),
    true = ets:insert(State0#state.tab, Session),
    I = State0#state.writei+1,
    Refs = array:set(I rem ?MAX_ACTIVE, Session#session.ref, State0#state.refs),
    State = State0#state{refs=Refs, writei=I},
    %% If the queue was empty before we pushed our new session to it, then
    %% immediately mark this session as active.
    case todo_empty(State0) of
        true -> next_todo(State);
        false -> State
    end.

next_todo(State0) ->
    %% XXX: may possibly remove this check for improved (?) performance
    ?DBG("next_todo", {readi,State0#state.readi, writei,State0#state.writei}),
    case todo_empty(State0) of
        true ->
            State = case is_idle(State0) of
                        true ->
                            State0;
                        false ->
                            I = State0#state.readi,
                            State0#state{readi=I+1}
                    end,
            case State#state.disconnect of
                true ->
                    State#state.pid ! disconnect,
                    State;
                false ->
                    State
            end;
        false ->
            Ref = output_ref(State0),
            [Req] = ets:lookup(State0#state.tab, Ref),
            Pid = State0#state.pid,
            I = State0#state.readi,
            State = State0#state{readi=I+1},
            case Req of
                #session{cache=Responds, closed=false} ->
                    replay(Responds, Pid),
                    State;
                #session{cache=Responds, closed=true} ->
                    replay(Responds, Pid),
                    Pid ! {respond,close},
                    ets:delete(State#state.tab, Ref),
                    next_todo(State)
            end
    end.

replay(undefined, _) -> ok;
replay(Responds, Pid) ->
    foreach(fun (Res) -> Pid ! {respond,Res} end, reverse(Responds)).
