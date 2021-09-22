-module(piroxy_hijack_ws).
-define(WS_GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").
-record(state, {sid,rawpid}).

-export([start_link/1,accept/1]).

%%%
%%% EXPORTS
%%%

start_link(Opts) ->
    case proplists:get_value(id, Opts) of
        undefined ->
            exit(badarg);
        Sid ->
            Pid = spawn_link(fun () -> init(Sid) end),
            {ok,Pid}
    end.

%%% Utility function to calculate the WebSocket accept header.
accept(Key) ->
    Digest = crypto:hash(sha,[Key|?WS_GUID]),
    base64:encode(Digest).

%%%
%%% INTERNALS
%%%

init(Sid) ->
    wait(#state{sid=Sid}).

wait(S) ->
    receive
        {handshake,Pid,WsPid} ->
            % Tell the ws_sock to relay frames to ourselves.
            link(WsPid),
            WsPid ! {hello,self(),{null,self()}},
            wait2(Pid,S);
        {hello,WsPid,{BinPid,_}} ->
            WsPid ! {howdy,self(),{null,self()}},
            loop(S#state{rawpid=BinPid})
    after 1000 ->
            exit(timeout)
    end.

wait2(Pid,S) ->
    receive
        {howdy,_,{BinPid,_}} ->
            Pid ! {handshake,ok},
            loop(S#state{rawpid=BinPid})
    after 1000 ->
            exit(timeout)
    end.

loop(State0) ->
    receive
        Any ->
            State = handle(Any,State0),
            loop(State)
    end.

handle({frame,{ping,Bin}}, S) ->
    %% respond to pings but do not generate them... yet
    reply({pong,Bin},S);

handle({frame,{binary,Bin}}, S0) ->
    %% all of our frames are binary
    Term = binary_to_term(Bin),
    io:format("*DBG* received: ~p~n", [Term]),
    {Res,S} = rpc(Term, S0),
    reply({binary,term_to_iovec(Res)}, S);

handle({frame,{close,L}}, S) ->
    %% we need to send a close in response
    reply({close,L}, S),
    exit(normal);

handle({frame,_}, S) ->
    %% ignore other frame types
    S.

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

reply(Term, #state{rawpid=Pid} = S) ->
    Bin = frame(Term),
    raw_sock:relay_binary(Pid,Bin),
    S.

%% close is the only frame which does not have a binary

frame({close,[]}) ->
    frame({close,<<>>});

frame({close,[Code]}) ->
    frame({close,<<Code:16>>});

frame({close,[Code,Reason]}) ->
    frame({close,<<Code:16,Reason/utf8>>});

%% generates a websocket frame, does not do any frame splitting
frame({Op,Bin}) when is_binary(Bin) ->
    Len = byte_size(Bin),
    if
        Len >= 4294967296 -> % 2^32
            <<1:1,0:3,(opcode(Op)):4,0:1,127:7,Len:64,Bin/binary>>;
        Len >= 126 -> % 126 and 127 are used for special lengths
            <<1:1,0:3,(opcode(Op)):4,0:1,126:7,Len:32,Bin/binary>>;
        true ->
            <<1:1,0:3,(opcode(Op)):4,0:1,Len:7,Bin/binary>>
    end;

frame(_) ->
    exit(badarg).

opcode(binary) -> 2;
opcode(close) -> 8;
opcode(pong) -> 10.
