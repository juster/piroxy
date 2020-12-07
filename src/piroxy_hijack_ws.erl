-module(piroxy_hijack_ws).
-define(GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").
-behavior(gen_server).
-record(state, {reply}).

-compile(export_all).

%%%
%%% EXPORTS
%%%

start() ->
    gen_server:start(?MODULE, [], []).

handshake(Pid, MFA) ->
    link(Pid),
    gen_server:call(Pid, {handshake,MFA}).

relay(Pid, Term) ->
    gen_server:cast(Pid, {websocket,Term}).

accept(Key) ->
    Digest = crypto:hash(sha, <<Key/binary, ?GUID>>),
    base64:encode(Digest).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    {ok, #state{}}.

handle_cast({websocket,{binary,_}}, S) ->
    %% ignore raw binaries
    {noreply, S};

handle_cast({websocket,{frame,{ping,Bin}}}, S) ->
    %% respond to pings but do not generate them... yet
    reply({pong,Bin}, S),
    {noreply, S};

handle_cast({websocket,{frame,{binary,Bin}}}, S) ->
    %% all of our frames are binary
    Term = binary_to_term(Bin),
    Res = rpc(Term, S),
    reply({binary,term_to_binary(Res)}, S),
    {noreply, S};

handle_cast({websocket,{frame,{close,L}}}, S) ->
    %% we need to send a close in response
    reply({close,L}, S),
    {noreply, S};

handle_cast({websocket,{frame,_}}, S) ->
    %% ignore other frame types
    {noreply, S}.

handle_call({handshake,MFA}, _From, S) ->
    {reply, {?MODULE,relay,[self()]}, S#state{reply=MFA}}.

rpc({filter,Filter}, _S) ->
    piroxy_ram_log:filter(Filter);

rpc(connections, _S) ->
    piroxy_ram_log:connections();

rpc({log,ConnId}, _S) ->
    piroxy_ram_log:log(ConnId);

rpc({body,Digest}, _S) ->
    piroxy_ram_log:body(Digest);

rpc(_, _S) ->
    {error,badrpc}.

reply(Term, S) ->
    {M,F,A} = S#state.reply,
    apply(M, F, A++[frame(Term)]).

%% close is the only frame which does not have a binary
frame({close,L}) when is_list(L) ->
    case L of
        [] ->
            frame({close,<<>>});
        [Code] ->
            frame({close,<<Code:16>>});
        [Code,Reason] ->
            frame({close,<<Code:16,Reason/utf8>>})
    end;

%% generates a websocket frame, does not do any frame splitting
frame({Op,Bin}) when is_binary(Bin) ->
    Len = byte_size(Bin),
    if
        Len >= 4294967296 ->
            <<1:1,0:3,(opcode(Op)):4,0:1,127:7,Len:64,Bin/binary>>;
        Len >= 126 ->
            <<1:1,0:3,(opcode(Op)):4,0:1,126:7,Len:32,Bin/binary>>;
        true ->
            <<1:1,0:3,(opcode(Op)):4,0:1,Len:7,Bin/binary>>
    end.

opcode(binary) -> 2;
opcode(close) -> 8;
opcode(pong) -> 10.
