%%% inbound_stream
%%% Streams requests and responses, one after another, allowing for pipelining
%%% requests to an outbound process. The responses to these requests are cached
%%% and streamed back to the (1) process that made the requests.

-module(inbound_stream).
-behavior(gen_server).
-include("pimsg.hrl").

-define(MAX_ACTIVE, 128).
-record(session, {ref, pid, index, reqbody=[], cache, closed=false}).
-record(state, {bufi=0, reqi=0, buffer, restab}).

-import(lists, [foreach/2, reverse/1]).
-export([start_link/0, receive_body/2]).
-export([init/1, terminate/2, handle_cast/2, handle_call/3]).

%%% external interface

start_link() ->
    gen_server:start_link(?MODULE, [], []).

receive_body(ServerRef, Chunk) ->
    gen_server:cast(ServerRef, {append_body,Chunk}).

%%% behavior callbacks

init([]) ->
    Buf = array:new([{size,?MAX_ACTIVE}, fixed]),
    Tab = ets:new(sessions, [set,private,{keypos,#session.ref}]),
    {ok, #state{buffer=Buf, restab=Tab}}.

terminate(_Reason, State) ->
    Tab = State#state.restab,
    cancel_requests(ets:first(Tab), Tab),
    ets:delete(Tab).

cancel_requests('$end_of_table', _) -> ok;
cancel_requests(Ref, Tab) ->
    request_manager:cancel_request(Ref),
    cancel_requests(ets:next(Ref, Tab), Tab).

handle_call({new,HostInfo,Head}, From, State) ->
    case request_manager:new_request(HostInfo, Head) of
        {error,Reason} ->
            {stop, Reason, State};
        {ok,Ref} ->
            I = State#state.reqi+1,
            Ses = #session{ref=Ref, pid=From, index=I},
            ets:insert(State#state.restab, Ses),
            case is_active(Ref, State) of
                true -> {reply, Ref, State#state{reqi=I}};
                false -> next_todo(State)
            end
    end;

%% called by outgoing process to retrieve the request body
handle_call({request_body,Ref}, _From, State) ->
    Tab = State#state.restab,
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
    Tab = State#state.restab,
    Ref = input_ref(State),
    [Res] = ets:lookup(Tab, Ref),
    Cache = Res#session.cache,
    ets:update(Tab, Ref, {#session.cache,[Chunk|Cache]}),
    {noreply, State};

handle_cast({close,Ref} = Msg, State) ->
    case send_if_active(Ref, Msg, State) of
        pending ->
            ets:update(State#state.restab, Ref, {#session.closed,true}),
            {noreply,State};
        active ->
            ets:delete(State#state.restab, Ref),
            {noreply,next_todo(State)}
    end;

handle_cast({reset,Ref} = Msg, State) ->
    case send_if_active(Ref, Msg, State) of
        pending ->
            ets:update(State#state.restab, Ref, [{#session.closed,false},
                                                 {#session.cache,undefined}]),
            {noreply,State};
        active ->
            {noreply,State}
    end;

handle_cast({respond,Ref,{head,_,_} = Head} = Msg, State) ->
    case send_if_active(Ref, Msg, State) of
        pending ->
            ets:update(State#state.restab, Ref, [{#session.cache,[Head]}]),
            {noreply,State};
        active ->
            %% no need to save if it is currently active
            {noreply,State}
    end;

handle_cast({respond,Ref,{body,_} = Body} = Msg, State) ->
    case send_if_active(Ref, Msg, State) of
        pending ->
            Tab = State#state.restab,
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
    end.

send_if_active(Ref, Msg, State) ->
    case is_active(Ref, State) of
        false -> pending;
        true ->
            [Res] = ets:lookup(State#state.restab, Ref),
            Res#session.pid ! Msg,
            active
    end.

output_ref(State) ->
    array:get(State#state.bufi rem ?MAX_ACTIVE, State#state.buffer).

is_active(Ref, State) ->
    case output_ref(State) of Ref -> true; _ -> false end.

input_ref(State) ->
    array:get(State#state.reqi rem ?MAX_ACTIVE, State#state.buffer).

buffer_empty(State) ->
    State#state.bufi =:= State#state.reqi.

next_todo(State0) ->
    %% XXX: may possibly remove this check for improved (?) performance
    case buffer_empty(State0) of
        true -> State0;
        false ->
            I = State0#state.bufi,
            State = State0#state{bufi = I+1},
            Ref = output_ref(State),
            [Req] = ets:lookup(State#state.restab, Ref),
            Pid = Req#session.pid,
            case Req of
                #session{cache=undefined} ->
                    %% doh, still waiting!
                    State;
                #session{cache=Responds, closed=false} ->
                    replay(Responds, Pid, Ref),
                    State;
                #session{cache=Responds, closed=true} ->
                    replay(Responds, Pid, Ref),
                    Pid ! {close,Ref},
                    ets:delete(State#state.restab, Ref),
                    next_todo(State)
            end
    end.

replay(Responds, Pid, Ref) ->
    foreach(fun (Res) -> Pid ! {respond,Ref,Res} end, reverse(Responds)).
