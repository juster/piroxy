%%% incoming_static
%%%
%%% Implements all of the "incoming" gen_server callbacks as well as new
%%% interface functions which send requests manually.

-module(inbound_static).
-behavior(gen_server).
-include("phttp.hrl").

-record(request, {ref, from, hostinfo, head, body}).
-record(response, {ref, status, headers, body}).

-export([start_link/0, send/3, send/4]).
-export([init/1, handle_cast/2, handle_call/3]).

%%%
%%% new interface functions
%%%

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% Returns a request Ref as provided from request_manager.
send(Pid, HostInfo, Head) ->
    gen_server:call(Pid, {send, HostInfo, Head}).

send(Pid, HostInfo, Head, Body) ->
    gen_server:call(Pid, {send, HostInfo, Head, Body}).

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
    MethodBin = method_bin(Method),
    UriBin = list_to_binary(Uri),
    case new_request(HostInfo, {MethodBin, UriBin, Headers}) of
        {error, Reason} ->
            {stop, Reason, State};
        {ok, Ref} ->
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
    [#response{status=StatusLine,headers=Headers,body=Body}] = ets:lookup(ResTab, Ref),
    ets:delete(ReqTab, Ref),
    ets:delete(ResTab, Ref),
    gen_server:reply(From, {ok, {StatusLine, Headers, Body}}),
    {noreply, State};

handle_cast({reset, Ref}, {ReqTab,ResTab} = State) ->
    case ets:lookup(ReqTab, Ref) of
        [] ->
            {stop, {request_missing, Ref}, State};
        [#request{hostinfo=HostInfo,head=Head}] ->
            {ok, NewRef} = new_request(HostInfo, Head),
            ets:update_element(ReqTab, Ref, {#request.ref, NewRef}),
            ets:delete(ResTab, Ref),
            ets:insert(ResTab, {Ref, null, null, ?EMPTY}),
            {noreply, State}
    end;

handle_cast({respond, Ref, {head, StatusLine, Headers}}, {_ReqTab,ResTab} = State) ->
    %%{{Major, Minor}, Status, _} = StatusLine, 
    case ets:update_element(ResTab, Ref, [{#response.status, StatusLine},
                                          {#response.headers, Headers}]) of
        true ->
            {noreply, State};
        false ->
            {stop, {request_missing, Ref}, State}
    end;

handle_cast({respond, Ref, {body, Body}}, {_ReqTab,ResTab} = State) ->
    [#response{body = PrevBody}] = ets:lookup(ResTab, Ref),
    NewBody = case PrevBody of
                  ?EMPTY -> Body;
                  PrevBody -> <<PrevBody/binary,Body/binary>>
              end,
    ets:update_element(ResTab, Ref, {#response.body, NewBody}),
    {noreply, State}.

method_bin(get) ->
    <<"GET">>;

method_bin(post) ->
    <<"POST">>;

method_bin(put) ->
    <<"PUT">>;

method_bin(delete) ->
    <<"DELETE">>.

new_request(HostInfo, Head) ->
    case request_manager:new_request(HostInfo, Head) of
        {error, Reason} ->
            {error, Reason};
        Ref ->
            io:format("*DBG* started request: ~p~n", [Ref]),
            {ok, Ref}
    end.
