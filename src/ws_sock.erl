-module(ws_sock).
-export([upgrade_options/1,start/1,connect/2]).
-record(state, {sid,socket,mode,relay,relayFrames=false,logging=false,
                buffer=(<<>>),fragments=[],zlib=null}).
-include_lib("kernel/include/logger.hrl").

%%%
%%% EXPORTS
%%%

upgrade_options(Headers) ->
    try
        upgrade_options_(Headers)
    catch raw ->
            [{mode,raw}]
    end.

%% Start a new websocket process.
%%
%% Opts (required):
%%  - socket :: from pisock_lib
%%  - logging :: boolean
%%  - id :: session id
%%  - buffer :: trailing bytes received after the upgrade message
%%  - headers :: HTTP headers (fieldlist) for the upgrade message
%%
start(Opts) ->
    case proplists:get_value(socket,Opts) of
        undefined ->
            {error,badarg};
        Sock ->
            %% Control of the socket must be passed to the new process.
            pisock_lib:setopts(Sock,[{active,false}]),
            Pid = proc_lib:spawn(fun () -> init(Opts) end),
            pisock_lib:controlling_process(Sock,Pid),
            {ok,Pid}
    end.

connect(Pid1,Pid2) ->
    Pid1 ! {connect,Pid2,self()},
    Pid2 ! {connect,Pid1,self()},
    receive
        {connected,Pid1} ->
            receive
                {connected,Pid2} ->
                    ok
            after 1000 ->
                    {error,timeout}
            end
    after 1000 ->
            {error,timeout}
    end.

%%%
%%% INTERNALS
%%%

upgrade_options_(Headers) ->
    B1 = fieldlist:has_value(<<"upgrade">>,<<"websocket">>,Headers),
    B2 = fieldlist:has_value(<<"connection">>,<<"upgrade">>,Headers),
    if
        B1, B2 ->
            Zlib = case fieldlist:get_lcase(<<"sec-websocket-extensions">>,Headers) of
                       <<"permessage-deflate">> ->
                           %% TODO: handle deflate extension parameters
                           X = zlib:open(),
                           %% XXX: An important (undocumented) feature of zlib
                           %% is that a negative window size tells it to NOT
                           %% look for the zlib header and CRC32 suffix!
                           zlib:inflateInit(X, -15),
                           X;
                       not_found ->
                           null;
                       _ ->
                           %% unknown extension(s), it's safer not to try to parse
                           throw(raw)
                   end,
            [{mode,ws},{zlib,Zlib}];
        true ->
            throw(raw)
    end.

init(Opts) ->
    State = #state{sid         = proplists:get_value(id,Opts),
                   socket      = proplists:get_value(socket,Opts),
                   mode        = proplists:get_value(mode,Opts),
                   relayFrames = proplists:get_bool(relayframes,Opts),
                   logging     = proplists:get_bool(logging,Opts),
                   buffer      = iolist_to_binary(proplists:get_value(buffer,Opts)),
                   zlib        = proplists:get_value(zlib,Opts)},
    loop(State).

loop(State0) ->
    receive
        Any ->
            %%io:format("*DBG* ws_sock ~p received: ~p~n", [self(),Any]),
            try handle(Any,State0) of
                State ->
                    loop(State)
            catch
                exit:closed ->
                    ok;
                exit:Rsn ->
                    ?LOG_ERROR("~s exit: ~p", [?MODULE,Rsn]),
                    exit(Rsn);
                error:Rsn:Stack ->
                    ?LOG_ERROR("~s error: ~p~n~p", [?MODULE,Rsn,Stack]),
                    exit(Rsn)
            end
    end.

handle({connect,Pid,Reply}, #state{socket=Sock} = S0) ->
    %% Link to the other process so we know if it errors out.
    process_flag(trap_exit,true),
    link(Pid),
    %% Activate the socket and start relaying data to Pid.
    pisock_lib:setopts(Sock,[{active,true}]),
    S = S0#state{relay=Pid},
    case S0#state.buffer of
        <<>> ->
            ok;
        Buf ->
            relay(Buf,S)
    end,
    Reply ! {connected,self()},
    S;

%% Relay messages are sent from the opposite end of the connection
handle({relay,Bin}, #state{socket=Sock} = S) when is_binary(Bin); is_list(Bin) ->
    pisock_lib:send(Sock,Bin),
    S;

%% We only convert {relay,{frame,...}} messages to binary and send them over our
%% socket when we are relaying frames to the opposite end.
handle({relay,Frame}, #state{relayFrames=false} = S) when is_tuple(Frame) ->
    S;

handle({relay,Frame}, #state{socket=Sock} = S) when is_tuple(Frame) ->
    pisock_lib:send(Sock,frame_binary(Frame)),
    S;

handle({relay,_},_) ->
    exit(badarg);

handle({X,_,Bin}, #state{mode=Mode} = S) when X == tcp; X == ssl ->
    %% TODO: binaries are not logged... maybe later?
    relay(Bin,S),
    case Mode of
        raw ->
            S;
        ws ->
            parse(Bin,S)
    end;

handle({X,_,Rsn},_) when X == tcp_error; X == ssl_error ->
    ?LOG_ERROR("ws_sock ~s: ~p", [X,Rsn]),
    exit({X,Rsn});

handle({X,_},S) when X == tcp_closed; X == ssl_closed ->
    log_event(close,null,S),
    exit(closed);

handle({'EXIT',Pid,closed}, #state{relay=Pid} = S) ->
    %% Both sides attempt to log the close event. Only one will succeed.
    log_event(close,null,S),
    exit(closed);

handle({'EXIT',_,Err}, #state{sid=Id,mode=Mode}) ->
    %% If the other side failed unexpectedly then we must always log this.
    ?LOG_ERROR("ws_sock unexpected exit: ~p", [Err]),
    piroxy_events:fail(Id,Mode,Err),
    exit(Err);

handle(_, _) ->
    exit(unknown_message).

%%%
%%% INTERNAL FUNCTIONS
%%%

relay(Bin, #state{relay=Pid,relayFrames=false})
  when is_binary(Bin); is_list(Bin) ->
    Pid ! {relay,Bin};

relay(T, #state{relay=Pid,relayFrames=true})
  when is_tuple(T) ->
    Pid ! {relay,T};

relay(_, _) ->
    ok.

parse(Bin2, #state{buffer=Bin1} = S)
  when byte_size(Bin1) + byte_size(Bin2) < 2 ->
    S#state{buffer=(<<Bin1/binary,Bin2/binary>>)};

parse(Bin2, #state{buffer=Bin1} = S1) ->
    Bin = <<Bin1/binary,Bin2/binary>>,
    <<Fin:1,Rsv1:1,_Rsv:2,Opcode:4,Masked:1,Len1:7,Rest1/binary>> = Bin,
    LenSize = case Len1 of 127 -> 64; 126 -> 16; _ -> 0 end,
    MaskSize = 4*Masked,
    case Rest1 of
        <<Len2:LenSize,Mask:MaskSize/bytes,Rest2/binary>> ->
            Len3 = case Len1 of 127 -> Len2; 126 -> Len2; _ -> Len1 end,
            if
                byte_size(Rest2) >= Len3 ->
                    {Payload0,Rest3} = split_binary(Rest2, Len3),
                    %%io:format("*DBG* parse: ~p~n",
                    %%          [[{fin,Fin},{rsv1,Rsv1},{opcode,Opcode},
                    %%            {len1,Len1},{lensize,LenSize},{len2,Len2},{len3,Len3},
                    %%            {masked,Masked},{mask,Mask}]]),
                    Payload = case Masked of
                                  0 -> Payload0;
                                  1 -> unmask(Payload0, Mask)
                              end,
                    S2 = reframe(Fin, Rsv1, operation(Opcode), Payload,
                                 S1#state{buffer=(<<>>)}),
                    parse(Rest3, S2); % keep parsing
                true ->
                    S1#state{buffer=Rest2}
            end;
        _ ->
            S1#state{buffer=Rest1}
    end.

unmask(Bin, Mask) ->
    unmask(Bin, Mask, 0, <<>>).

unmask(<<>>, _Mask, _I, Y) ->
    Y;

unmask(<<X:8,A/binary>>, Mask, I, B) ->
    Y = X bxor binary:at(Mask, I rem 4),
    unmask(A, Mask, I+1, <<B/binary,Y:8>>).

%%% Args: Fin, OpAtom, Payload, #state{}

reframe(1, _, continuation, Payload, S) ->
    %% frame is at the end of fragments
    case S#state.fragments of
        %% if frame is the end there must be previous fragments in the queue
        [] -> error(badstate);
        [[]|_] -> error(badstate);
        [L0|Q] ->
            %% pop fragments off the queue
            [{Op,Rsv1}|L] = lists:reverse([Payload|L0]),
            send_frame(Rsv1, Op, iolist_to_binary(L), S#state{fragments=Q})
    end;

reframe(1, Rsv1, Op, Payload, S) ->
    %% frame is both the alpha and the 0MEGA!
    send_frame(Rsv1, Op, Payload, S);

reframe(0, _, continuation, Payload, S) ->
    %% frame is in the middle of a stream of fragments
    case S#state.fragments of
        %% if frame is in the middle there must be previous fragments in the
        %% queue
        [] -> error(badstate);
        [[]|_] -> error(badstate);
        [L0|Q] ->
            L = [Payload|L0],
            S#state{fragments=[L|Q]}
    end;

reframe(0, Rsv1, Op, Payload, #state{fragments=Q}=S) ->
    %% this frame is the beginning of fragments
    %% push a new list to the front of the list queue
    %% the list is in reverse, so op atom goes last
    L = [Payload,{Op,Rsv1}],
    S#state{fragments=[L|Q]}.

operation(0) -> continuation;
operation(1) -> text;
operation(2) -> binary;
operation(3) -> nonctrl3; % reserved non-control frames
operation(4) -> nonctrl4;
operation(5) -> nonctrl5;
operation(6) -> nonctrl6;
operation(7) -> nonctrl7;
operation(8) -> close;
operation(9) -> ping;
operation(10) -> pong.

send_frame(Rsv1, Op, Payload0, S) ->
    Bin = case {Rsv1,S#state.zlib} of
                  {1,null} ->
                      %% XXX: compression used but not negotiated!
                      Payload0;
                  {1,Z} ->
                      inflate(Z, Payload0);
                  {0,_} ->
                      Payload0
              end,
    Frame = case Op of
                close ->
                    %% close sends a list as argument
                    L = case Bin of
                            <<>> ->
                                [];
                            <<Code:16>> ->
                                [Code];
                            <<Code:16,Reason/binary>> ->
                                [Code,Reason]
                        end,
                    {Op,L};
                _ ->
                    {Op,Bin}
            end,
    log_event(Frame,S),
    relay(Frame,S),
    S.

inflate(Z, Bin0) ->
    %% These extra octets are always the same and so removed/appended.
    Bin = <<Bin0/binary,0,0,255,255>>,
    %% TODO: idk what to do if it "needs" some "dict"
    zlib:inflate(Z, Bin, [{exception_on_need_dict,true}]).
    %% I believe future messages depend on previous message state.
    %%zlib:inflateReset(Z).

opcode(binary) -> 2;
opcode(close) -> 8;
opcode(pong) -> 10.

%% close is the only frame which does not have a binary
frame_binary({close,[]}) ->
    frame_binary({close,<<>>});

frame_binary({close,[Code]}) ->
    frame_binary({close,<<Code:16>>});

frame_binary({close,[Code,Reason]}) ->
    frame_binary({close,<<Code:16,Reason/utf8>>});

%% generates a websocket frame, does not do any frame splitting
frame_binary({Op,L}) when is_list(L) ->
    frame_binary({Op,iolist_to_binary(L)});

frame_binary({Op,Bin}) when is_binary(Bin) ->
    Len = byte_size(Bin),
    if
        Len >= 4294967296 -> % 2^32
            <<1:1,0:3,(opcode(Op)):4,0:1,127:7,Len:64,Bin/binary>>;
        Len >= 126 -> % 126 and 127 are used for special lengths
            <<1:1,0:3,(opcode(Op)):4,0:1,126:7,Len:32,Bin/binary>>;
        true ->
            <<1:1,0:3,(opcode(Op)):4,0:1,Len:7,Bin/binary>>
    end;

frame_binary(_) ->
    exit(badarg).

log_event(Term, #state{logging=A} = S) ->
    log_event(A, Term, S).

log_event(_, _, #state{logging=false}) ->
    ok;

log_event(A, Term, #state{sid=Id,mode=Mode}) ->
    piroxy_events:log(Id,Mode,A,Term).
