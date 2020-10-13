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
-include("../include/phttp.hrl").

-define(MAX_ACTIVE, 128).

%%
%% The request queue is streamed in the order that it is received from the client.
%% Request queue is in normal order, because we must relay all request chunks
%% we have received, anyways.
%%
%% Response queue is in reverse order, so that we can see if the response stream
%% has been closed, yet.
%%
-record(state, {pid, host, reqQ=[], respQ=[]}).

-import(lists, [foreach/2, reverse/1, reverse/2]).
-export([start_link/0, start_link/1, stream_request/2, finish_request/1]).
-export([reflect/2, disconnect/1, force_host/2]).
-export([init/1, terminate/2, handle_cast/2, handle_call/3, handle_continue/2]).

%%% external interface

start_link() ->
    gen_server:start_link(?MODULE, [self()], []).

start_link(Name) ->
    gen_server:start_link({local,Name}, ?MODULE, [self()], []).

stream_request(ServerRef, Chunk) ->
    gen_server:cast(ServerRef, {stream_request,Chunk}).

finish_request(ServerRef) ->
    gen_server:cast(ServerRef, finish_request).

reflect(ServerRef, Messages) ->
    gen_server:cast(ServerRef, {reflect,Messages}).

%% end the connection but only after pending responses in the
%% pipeline are relayed
disconnect(ServerRef) ->
    gen_server:cast(ServerRef, disconnect).

force_host(ServerRef, {_,_,_} = HostInfo) ->
    gen_server:cast(ServerRef, {force_host,HostInfo}).

%%% behavior callbacks

init([Pid]) ->
    {ok, #state{pid=Pid}}.

terminate(_Reason, S) ->
    foreach(fun ({Ref,_}) ->
                    request_manager:cancel_request(Ref)
            end, S#state.respQ).

handle_call({new,HostInfo1,Head}, _From, S0) ->
    try
        HostInfo = case {HostInfo1, S0#state.host} of
                       {null,undefined} ->
                           throw(host_missing);
                       {null,HostInfo2} ->
                           HostInfo2;
                       {HostInfo2,undefined} ->
                           HostInfo2;
                       _ ->
                           throw(host_duplicated)
                   end,
        Ref = request_manager:new_request(HostInfo, Head),
        Q1 = S0#state.reqQ,
        Q2 = S0#state.respQ,
        S = S0#state{reqQ=Q1 ++ [{Ref,[]}],
                     respQ=Q2 ++ [{Ref,[]}]},
        {reply, {ok,Ref}, S}
    catch
        Reason ->
            {reply, {error,Reason}, S0}
    end;

%% called by outgoing process to retrieve the request body (out of order)
handle_call({request_body,Ref}, From, S) ->
    case find(Ref, S#state.reqQ) of
        not_found ->
            %% {Ref,...} entry should have been added to the
            %% queue.
            {reply,{error,unknown_ref},S};
        {found,{blocked,From},_,_} ->
            %% we cannot block again because we are already blocked
            %% (why is there another request_body for the same Ref?)
            {reply,{error,already_blocked},S};
        {found,[],Q1,Q2} ->
            %% block the call if the request body has not yet been sent
            %% by the client
            Q = reverse(Q1, [{Ref,{blocked,From}}|Q2]),
            {noreply,S#state{reqQ=Q}};
        {found,[done],_,_} ->
            %% the request chunks are finished. if possible, stream the response
            %% back to the client.
            {reply,done,S,{continue,stream_responses}};
        {found,[T|L],Q1,Q2} ->
            %% relay chunks in the order they were received
            Q = reverse(Q1, [{Ref,L}|Q2]),
            {reply,{some,T},S#state{reqQ=Q}}
    end.

%% called by client to append to request body (in order)
handle_cast({stream_request,?EMPTY}, S) ->
    {noreply, S};

handle_cast({stream_request,<<>>}, S) ->
    {noreply, S};

handle_cast({stream_request,Chunk}, S) ->
    %% request should be the last in the queue
    case reverse(S#state.reqQ) of
        [] ->
            %% Queue should not be empty!
            {stop,internal_error,S};
        [{Ref,[done]}|_] ->
            %% request_end was called previously so we cannot
            %% store more chunks
            {stop,{request_queue_closed,Ref},S};
        [{Ref,{blocked,From}}|Q0] ->
            %% we have blocked an outbound call and can bypass the
            %% chunk queue
            gen_server:reply(From, {some,Chunk}),
            Q = reverse(Q0, [{Ref,[]}]),
            {noreply,S#state{reqQ=Q}};
        [{Ref,L0}|Q0] ->
            %% append chunk to the list of chunks to relay
            L = L0 ++ [Chunk],
            Q = reverse(Q0, [{Ref,L}]),
            {noreply,S#state{reqQ=Q}}
    end;

%% called by client to mark the end of request chunks (in-order)
handle_cast(finish_request, S) ->
    case reverse(S#state.reqQ) of
        [] ->
            %% Queue should not be empty!
            {noreply,S};
        [{_,[done]}|_] ->
            %% request_end was already called
            {stop,request_queue_closed,S};
        [{Ref,{blocked,From}}|Q0] ->
            %% we have blocked an outbound call and can bypass the
            %% queue
            gen_server:reply(From, done),
            Q = reverse(Q0, [{Ref,[done]}]),
            {noreply,S#state{reqQ=Q},{continue,stream_responses}};
        [{Ref,L}|Q0] ->
            %% prepend 'done' to the last request's list of chunks
            Q = reverse(Q0, [{Ref,L++[done]}]),
            {noreply,S#state{reqQ=Q},{continue,stream_responses}}
    end;

%% inbound:close() called by request_manager means responses are finished
handle_cast({close,Ref}, S) ->
    case find(Ref, S#state.respQ) of
        not_found ->
            ?DBG("close", notfound),
            {stop, {unknownref,Ref}, S};
        {found, L, Q1, Q2} ->
            %% prepend 'done' to the message queue
            Q = reverse(Q1, [{Ref,[done|L]}|Q2]),
            ?DBG("close", {state,S#state{respQ=Q}}),
            %% prime the pump just in case it needs it
            {noreply,S#state{respQ=Q},{continue,stream_responses}}
    end;

handle_cast({reset,Ref}, S) ->
    %% empty the message queue for Ref in both the request and response queue
    case {find(Ref, S#state.reqQ), find(Ref,S#state.respQ)} of
        {{found,_,Q1,Q2}, {found,_,Q3,Q4}} ->
            {noreply, S#state{reqQ=reverse(Q1,[{Ref,[]}|Q2]),
                              respQ=reverse(Q3,[{Ref,[]}|Q4])}};
        _ ->
            %% invalid reference, log it?
            {noreply,S}
    end;

%% TODO: change name from fail to error
handle_cast({fail,Ref,Reason}, S) ->
    case find(Ref, S#state.respQ) of
        not_found ->
            %% error?
            {noreply, S};
        {found, [done|_], _, _} ->
            ?DBG("fail", "cannot append error to closed stream"),
            {noreply, S};
        {found, L0, Q1, Q2} ->
            L = [done,{fail,Ref,Reason}|L0],
            {noreply,S#state{respQ=reverse(Q1,[{Ref,L}|Q2])},
             {continue,stream_responses}}
    end;

handle_cast({respond,Ref,T}, S) ->
    case find(Ref, S#state.respQ) of
        not_found ->
            {stop, {unknownref,Ref}, S};
        {found, L, Q1, Q2} ->
            Q = reverse(Q1, [{Ref,[T|L]}|Q2]),
            {noreply,S#state{respQ=Q},{continue,stream_responses}}
    end;

%% reflect response back (called by client, in-order)
handle_cast({reflect,L1},S) ->
    case reverse(S#state.respQ) of
        [] ->
            replay(L1, S),
            {noreply, S};
        [{Ref,L2}|Q0] ->
            L = reverse(L1, L2),
            Q = reverse([{Ref,L}|Q0]),
            {noreply,S#state{respQ=Q},{continue,stream_responses}}
    end;

handle_cast(disconnect,S) ->
    Q1 = S#state.reqQ ++ [{null,[done]}],
    Q2 = S#state.respQ ++ [{null, [done,disconnect]}],
    {noreply, S#state{reqQ=Q1, respQ=Q2},{continue,stream_responses}};

handle_cast({force_host,HostInfo}, S) ->
    {noreply, S#state{host=HostInfo}}.

relay(Msg, S) ->
    S#state.pid ! {respond,Msg}.

replay(Msgs, S) ->
    foreach(fun (Msg) -> relay(Msg, S) end, Msgs).

find(X, L1) -> find(X, L1, []).
find(X, [{X,Y}|L1], L2) -> {found,Y,L2,L1}; % reverse(L2, [T|L1]) rebuilds
find(X, [Z|L1], L2) -> find(X, L1, [Z|L2]);
find(_, [], _) -> not_found.

handle_continue(stream_responses, #state{reqQ=[], respQ=[]} = S) ->
    {noreply, S};

handle_continue(stream_responses, S) ->
    %% Assumes: queues are not empty.
    case {hd(S#state.reqQ), hd(S#state.respQ)} of
        {{Ref1,_}, {Ref2,_}} when Ref1 =/= Ref2 ->
            %% Sanity check: references should be identical
            {stop, ref_mismatch, S};
        {{Ref,[done]}, {Ref,[]}} ->
            %% Special case: no responses received yet
            {noreply, S};
        {{Ref,[done]}, {Ref,[done|L]}} ->
            ?DBG("stream_responses", both_done),
            %% Both request and response queues have been tagged done
            replay(reverse(L), S),
            relay(close, S),
            %% Pop the top request/response entries in both queues
            {noreply,
             S#state{reqQ=tl(S#state.reqQ), respQ=tl(S#state.respQ)},
             {continue,stream_responses}};

        {{Ref,[done]}, {Ref,L}} ->
            %% Responses are not finished yet, relay what we have and reset
            %% the queue.
            replay(reverse(L), S),
            {noreply, S#state{respQ=[{Ref,[]}|tl(S#state.respQ)]}};
        _ ->
            %% Request chunks are still coming in.
            {noreply, S}
    end.
