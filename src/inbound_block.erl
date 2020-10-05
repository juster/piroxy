%%% inbound_block
%%%
%%% Blocks on sends: calling send does not return until the HTTP response
%%% has been received. The response is returned as the result of the call
%%% to send.

-module(inbound_block).
-behavior(gen_server).
-include("../include/phttp.hrl").
-import(lists, [reverse/1]).

-export([start_link/0, start_link/1, send/3, send/4]).
-export([init/1, handle_cast/2, handle_call/3]).

%%%
%%% new interface functions
%%%

start_link() ->
    gen_server:start_link(?MODULE, [], []).

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

send(ServerRef, HostInfo, Head) ->
    send(ServerRef, HostInfo, Head, []).

send(ServerRef, HostInfo, Head, Body) ->
    gen_server:call(ServerRef, {send,HostInfo,Head,Body}, infinity).

%%%
%%% behavior callbacks
%%%

init([]) ->
    {ok, idle}.

handle_call({new,_,_}, _, State) ->
    %% use send instead of new
    {stop, unimplemented, State};

handle_call({send, HostInfo, Head, Body}, From, idle) ->
    Ref = request_manager:new_request(HostInfo, Head),
    {noreply, {Ref,From,Body,null,[]}};

handle_call({send,_,_,_}, _, _) ->
    {reply, {error,already_sending}};

handle_call({request_body,Ref}, _From, {Ref,_,Body,_,_}=S) ->
    {reply, {last,Body}, S}.

%% called by request_manager to notify end of response
handle_cast({close,Ref}, {Ref,From,_,Head,Body}) ->
    case Head of
        null ->
            gen_server:reply(From, {error,head_missing});
        #head{line=StatusLine, headers=Headers} ->
            T = {StatusLine,Headers,reverse(Body)},
            gen_server:reply(From, {ok,T});
        _ ->
            error({unknown,Head})
    end,
    {noreply,idle};

handle_cast({reset,Ref}, {Ref,From,Body,_,_}) ->
    {noreply, {Ref,From,Body,null,[]}};

handle_cast({respond,Ref,{head,Head}}, {Ref,_,_,null,_}=S) ->
    {noreply, setelement(4, S, Head)};

handle_cast({respond,Ref,{body,Chunk}}, {Ref,_,_,_,Body}=S) ->
    {noreply, setelement(5, S, [Chunk|Body])};

handle_cast({fail,Ref,Reason}, {Ref,From,_,_,_}) ->
    gen_server:reply(From, {error,Reason}),
    {noreply, idle}.
