%%% incoming_static
%%%
%%% Implements all of the "incoming" gen_server callbacks as well as new
%%% interface functions which send requests manually.
%%%
%%% Blocks on sends, calling send does not return until the HTTP response
%%% has been received. The response is returned as the result of the send.

-module(inbound_static).
-behavior(gen_server).
-include("phttp.hrl").

-define(TIMEOUT, 20000).

-record(request, {ref, from, hostinfo, head, body=[]}).
-record(response, {ref, status, headers, body=[]}).

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
    {ok, {ets:new(requests, [set,private,{keypos,#request.ref}]),
          ets:new(responses, [set,private,{keypos,#response.ref}])}}.

handle_call({new, HostInfo, Head}, From, State) ->
    case request_manager:new_request(HostInfo, Head) of
        {error,Reason} ->
            {stop, Reason, State};
        {ok,Ref} ->
            {ReqTab,ResTab} = State,
            ets:insert(ReqTab, #request{ref=Ref, from=From, head=Head,
                                        hostinfo=HostInfo}),
            ets:insert(ResTab, #response{ref=Ref}),
            {reply, Ref, State}
    end;

handle_call({send, HostInfo, Head, Body}, From, State0) ->
    case handle_call({new,HostInfo,Head}, From, State0) of
        {stop,_,_} = T -> T;
        {reply,Ref,State} ->
            {ReqTab,_} = State,
            case Body of
                [] -> ok;
                _ ->
                    ets:update_element(ReqTab, Ref, {#request.body,Body})
            end,
            {noreply, State} % don't return but block
    end;

handle_call({request_body, Ref}, _From, State) ->
    {ReqTab,_} = State,
    [Req] = ets:lookup(ReqTab, Ref),
    {reply, {last, Req#request.body}, State}.

handle_cast({close, Ref}, State) ->
    {ReqTab,ResTab} = State,
    [Req] = ets:lookup(ReqTab, Ref),
    [Res] = ets:lookup(ResTab, Ref),
    From = Req#request.from,
    #response{status=StatusLine,headers=Headers,body=Body} = Res,
    ets:delete(ReqTab, Ref),
    ets:delete(ResTab, Ref),
    gen_server:reply(From, {ok,{StatusLine,Headers,Body}}),
    {noreply, State};

handle_cast({reset, Ref}, State) ->
    {ReqTab,ResTab} = State,
    case ets:lookup(ReqTab, Ref) of
        [] ->
            {stop, {request_missing, Ref}, State};
        [#request{hostinfo=HostInfo,head=Head}] ->
            {ok,NewRef} = request_manager:new_request(HostInfo, Head),
            true = ets:update_element(ReqTab, Ref, {#request.ref, NewRef}),
            true = ets:update_element(ResTab, Ref, [{#response.status, null},
                                                    {#response.headers, null},
                                                    {#response.body, []}]),
            {noreply,State}
    end;

handle_cast({respond, Ref, {head,Head}}, State) ->
    #head{line=StatusLine, headers=Headers} = Head,
    {_ReqTab,ResTab} = State,
    case ets:update_element(ResTab, Ref, [{#response.status, StatusLine},
                                          {#response.headers, Headers}]) of
        true -> {noreply,State};
        false -> {stop, {request_missing,Ref}, State}
    end;

handle_cast({respond, Ref, {body,Body}}, {_ReqTab,ResTab} = State) ->
    [#response{body=PrevBody}] = ets:lookup(ResTab, Ref),
    NewBody = case PrevBody of
                  ?EMPTY -> Body;
                  PrevBody -> [PrevBody|Body] % append to iolist
              end,
    ets:update_element(ResTab, Ref, {#response.body, NewBody}),
    {noreply,State};

handle_cast({fail,Ref,Reason}, {ReqTab,ResTab}=State) ->
    case ets:lookup(ReqTab, Ref) of
        [] -> {noreply, State};
        [Req] ->
            ets:delete(ReqTab, Ref),
            ets:delete(ResTab, Ref),
            gen_server:reply(Req#request.from, {error,Reason}),
            {noreply, State}
    end.

%%new_request(HostInfo, Head) ->
%%    case request_manager:new_request(HostInfo, Head) of
%%        {ok,Ref} = Result ->
%%            %%io:format("*DBG* started request: ~p~n", [Ref]),
%%            Result;
%%        Etc ->
%%            Etc
%%    end.
