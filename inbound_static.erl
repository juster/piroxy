%%% incoming_static
%%%
%%% Implements all of the "incoming" gen_server callbacks as well as new
%%% interface functions which send requests manually.

-module(inbound_static).
-behavior(gen_server).
-include("phttp.hrl").

-define(TIMEOUT, 20000).

-record(request, {ref, from, hostinfo, head, body}).
-record(response, {ref, status, headers, body}).

-export([start_link/0, start_link/1, send/3, send/4]).
-export([init/1, handle_cast/2, handle_call/3]).

%%%
%%% new interface functions
%%%

start_link() ->
    gen_server:start_link(?MODULE, [], []).

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

%% Returns a request Ref as provided from request_manager.
send(Pid, HostInfo, Head) ->
    gen_server:call(Pid, {send, HostInfo, Head}, ?TIMEOUT).

send(Pid, HostInfo, Head, Body) ->
    gen_server:call(Pid, {send, HostInfo, Head, Body}, ?TIMEOUT).

%%%
%%% behavior callbacks
%%%

init([]) ->
    {ok, {ets:new(requests, [set,private,{keypos,#request.ref}]),
          ets:new(responses, [set,private,{keypos,#response.ref}])}}.

handle_call({send, HostInfo, Head}, From, State) ->
    handle_call({send, HostInfo, Head, ?EMPTY}, From, State);

handle_call({send, HostInfo, Head, Body}, From, {ReqTab,ResTab} = State) ->
    {Method, Uri, Headers} = Head,
    MethodBin = phttp:method_bin(Method),
    UriBin = unicode:characters_to_binary(Uri),
    case request_manager:new_request(HostInfo, {MethodBin, UriBin, Headers}) of
        {error,Reason} ->
            {stop, Reason, State};
        {ok,Ref} ->
            Req = {request, Ref, From, HostInfo,
                   {MethodBin, UriBin, Headers}, Body},
            ets:insert(ReqTab, Req),
            ets:insert(ResTab, {response, Ref, null, null, ?EMPTY}),
            {noreply, State}
    end;

handle_call({request, Ref, body}, _From, {ReqTab,_ResTab} = State) ->
    Req = hd(ets:lookup(ReqTab, Ref)),
    {reply, {last, Req#request.body}, State}.

handle_cast({close, Ref}, {ReqTab,ResTab} = State) ->
    [#request{from=From}] = ets:lookup(ReqTab, Ref),
    [Resp] = ets:lookup(ResTab, Ref),
    #response{status=StatusLine,headers=Headers,body=Body} = Resp,
    ets:delete(ReqTab, Ref),
    ets:delete(ResTab, Ref),
    gen_server:reply(From, {ok, {StatusLine, Headers, Body}}),
    {noreply, State};

handle_cast({reset, Ref}, {ReqTab,ResTab} = State) ->
    case ets:lookup(ReqTab, Ref) of
        [] ->
            {stop, {request_missing, Ref}, State};
        [#request{hostinfo=HostInfo,head=Head}] ->
            {ok,NewRef} = request_manager:new_request(HostInfo, Head),
            true = ets:update_element(ReqTab, Ref, {#request.ref, NewRef}),
            true = ets:update_element(ResTab, Ref, [{#response.status, null},
                                                    {#response.headers, null},
                                                    {#response.body, ?EMPTY}]),
            {noreply, State}
    end;

handle_cast({respond, Ref, {head,StatusLine,Headers}}, State) ->
    {_ReqTab,ResTab} = State,
    %%{{Major, Minor}, Status, _} = StatusLine,
    case ets:update_element(ResTab, Ref, [{#response.status, StatusLine},
                                          {#response.headers, Headers}]) of
        true ->
            {noreply, State};
        false ->
            {stop, {request_missing, Ref}, State}
    end;

handle_cast({respond, Ref, {body,Body}}, {_ReqTab,ResTab} = State) ->
    [#response{body=PrevBody}] = ets:lookup(ResTab, Ref),
    NewBody = case PrevBody of
                  ?EMPTY -> Body;
                  PrevBody -> [PrevBody|Body] % append to iolist
              end,
    ets:update_element(ResTab, Ref, {#response.body, NewBody}),
    {noreply, State}.

%%new_request(HostInfo, Head) ->
%%    case request_manager:new_request(HostInfo, Head) of
%%        {ok,Ref} = Result ->
%%            %%io:format("*DBG* started request: ~p~n", [Ref]),
%%            Result;
%%        Etc ->
%%            Etc
%%    end.
