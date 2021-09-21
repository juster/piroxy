-module(ws_sock).
-export([start_link/1,handshake/2,frame_to/2,relay_frame/2]).
-record(state, {sid,relay,rawpid,buffer=(<<>>),fragments=[],z=null}).
-include_lib("kernel/include/logger.hrl").

%%%
%%% EXPORTS
%%%

start_link(Opts0) ->
    case raw_sock:start_link(Opts0) of
        {ok,Pid1} ->
            Opts = [{rawpid,Pid1}|Opts0],
            Pid2 = spawn_link(fun () -> init(Opts) end),
            unlink(Pid1),
            {ok,Pid2};
        Any ->
            Any
    end.

handshake(Pid1, Pid2) ->
    Pid1 ! {handshake,frame,Pid2}.

frame_to(Pid1, Pid2) ->
    Pid1 ! {frame_to,Pid2}.

relay_frame(Pid1, Frame) ->
    Pid1 ! {frame,Frame}.

%%%
%%% INTERNALS
%%%

init(Opts) ->
    io:format("*DBG* ws_sock: Opts=~p~n", [Opts]),
    Z = case proplists:get_bool(deflate, Opts) of
            true ->
                X = zlib:open(),
                %% An important (undocumented) feature of zlib is that a
                %% negative window size tells it to NOT look for the zlib
                %% header and CRC32 suffix!
                zlib:inflateInit(X, -15),
                X;
            false ->
                null
        end,
    [Sid,RawPid] = [proplists:get_value(A,Opts) || A <- [id,rawpid]],
    case lists:member(undefined,[Sid]) of
        true ->
            exit(badarg);
        false ->
            loop(#state{sid=Sid,z=Z,rawpid=RawPid})
    end.

loop(State0) ->
    receive
        Any ->
            State = handle(Any,State0),
            loop(State)
    end.

handle({binary_to,Pid}, S) ->
    raw_sock:binary_to(S#state.rawpid,Pid),
    S;

handle({frame_to,_}, S) ->
    S;

handle({handshake,Pid}, S) ->
    %% Tell the opposite socket to route directly to the raw_sock.
    raw_sock:binary_to(Pid, S#state.rawpid);

handle({binary_to,Pid}, S) ->
    %% Start routing binaries from the raw_sock we wrap both to ourselves
    %% and to the opposite side.
    raw_sock:binary_to(S#state.rawpid,[Pid,self()]);

handle({binary,Bin}, S) ->
    parse(Bin,S);

handle(Any, S) ->
    ?LOG_WARNING("ws_sock: unknown message ~p", [Any]),
    S.

%%%
%%% INTERNAL FUNCTIONS
%%%

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
    Bin = case {Rsv1,S#state.z} of
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
    relay_frame(S#state.relay, Frame),
    S.

inflate(Z, Bin0) ->
    %% These extra octets are always the same and so removed/appended.
    Bin = <<Bin0/binary,0,0,255,255>>,
    %% TODO: idk what to do if it "needs" some "dict"
    zlib:inflate(Z, Bin, [{exception_on_need_dict,true}]).
    %% I believe future messages depend on previous message state.
    %%zlib:inflateReset(Z).
