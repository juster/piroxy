-module(ws_sock).
-behavior(gen_statem).
-include_lib("kernel/include/logger.hrl").
-import(lists, [reverse/1]).

-record(data, {id,mfa,role,socket,buffer=(<<>>),queue=[],z=null}).

-export([start/3, handshake/2, websocket/2]).
-export([init/1, callback_mode/0, handle_event/4]).

%%%
%%% EXPORTS
%%%

start(Sock, Bin, Opts) ->
    case gen_statem:start(?MODULE, Opts, []) of
        {ok,Pid}=T ->
            pisock:setopts(Sock, [{active,false}]),
            pisock:control(Sock, Pid),
            gen_statem:cast(Pid, {upgrade,Sock,Bin}),
            T;
        {error,_}=Err ->
            Err
    end.

handshake(Pid, MFA) ->
    %% Append the caller's pid to form an MFA for the callback!
    link(Pid),
    gen_statem:call(Pid, {handshake,MFA}).

websocket(Pid, Term) ->
    gen_statem:cast(Pid, {websocket,Term}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

callback_mode() -> [handle_event_function].

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
    Id = proplists:get_value(id, Opts),
    case Id of
        undefined -> exit(badarg);
        _ -> ok
    end,
    Server = proplists:get_bool(server, Opts),
    Client = proplists:get_bool(client, Opts),
    Role = if
               Server -> server;
               Client -> client;
               true -> exit(badarg)
           end,
    case proplists:get_value(handshake, Opts) of
        undefined ->
            {ok, intro, #data{id=Id,role=Role,z=Z}};
        {M,F,A} ->
            MFA1 = {?MODULE,websocket,[self()]}, % callback MFA
            MFA2 = apply(M,F,A++[MFA1]), % send it to the handshake MFA
            % it returns it's own callback MFA, store it for later
            {ok, take_socket, #data{mfa=MFA2,id=Id,role=Role,z=Z}}
    end.

handle_event({call,From}, {handshake,MFA}, intro, D) ->
    %% Receive the MFA the caller wants us to apply, for sending websocket
    %% messages. Return the MFA we want the caller to apply for relaying
    %% websocket messages to ourselves.
    {next_state, take_socket, D#data{mfa=MFA},
     {reply, From, {?MODULE,websocket,[self()]}}};

handle_event(cast, {upgrade,Sock,Bin}, take_socket, D) ->
    case pisock:setopts(Sock, [{active,true}]) of
        ok ->
            {next_state, active, D#data{socket=Sock},
             case Bin of
                 <<>> -> [];
                 _ -> {next_event,info,{tcp,null,Bin}}
             end};
        {error,Rsn} when Rsn == closed; Rsn == einval ->
            {stop,shutdown};
        {error,_}=Err ->
            {stop,Err}
    end;

handle_event(_, _, A, _)
  when A == intro; A == take_socket ->
    {keep_state_and_data, postpone};

handle_event(cast, {websocket,Bin}, active, D) when is_binary(Bin)->
    %% raw binary is sent in order to be relayed across the opposite socket
    pisock:send(D#data.socket, Bin),
    keep_state_and_data;

handle_event(cast, {websocket,Frame}, active, _) when is_tuple(Frame) ->
    %% ignore frames received from the other socket, these are for other types
    %% of receivers
    keep_state_and_data;

handle_event(info, {A,_,Bin}, active, D0)
  when A =:= tcp; A =:= ssl ->
    %% relay binaries to the opposite socket owner
    relay(Bin, D0),
    D = parse(Bin, D0),
    {keep_state,D};

handle_event(info, {A,_}, active, _D)
  when A =:= tcp_closed; A =:= ssl_closed ->
    {stop,shutdown};

handle_event(info, {A,_,Reason}, active, _D)
  when A =:= tcp_error; A =:= ssl_error ->
    exit(Reason).

%%%
%%% INTERNAL FUNCTIONS
%%%

relay(T, D) when is_tuple(T) ->
    Id = D#data.id,
    case D#data.role of
        client ->
            piroxy_events:send(Id, ws, T);
        server ->
            piroxy_events:recv(Id, ws, T)
    end,
    relay_(T, D);

relay(Any, D) ->
    relay_(Any, D).

relay_(Any, D) ->
    {M,F,A} = D#data.mfa,
    apply(M, F, A++[Any]).

parse(Bin2, D) when size(Bin2) + size(D#data.buffer) < 2 ->
    Bin1 = D#data.buffer,
    D#data{buffer=(<<Bin1/binary,Bin2/binary>>)};

parse(Bin2, D) ->
    Bin = <<(D#data.buffer)/binary,Bin2/binary>>,
    <<Fin:1,Rsv1:1,_Rsv:2,Opcode:4,Masked:1,Len1:7,Rest1/binary>> = Bin,
    LenSize = case Len1 of 127 -> 64; 126 -> 16; _ -> 0 end,
    MaskSize = 4*Masked,
    case Rest1 of
        <<Len2:LenSize, Mask:MaskSize/bytes, Rest2/binary>> ->
            Len3 = case Len1 of 127 -> Len2; 126 -> Len2; _ -> Len1 end,
            if
                size(Rest2) >= Len3 ->
                    {Payload0,Rest3} = split_binary(Rest2, Len3),
                    %%io:format("*DBG* parse: ~p~n",
                    %%          [[{fin,Fin},{rsv1,Rsv1},{opcode,Opcode},
                    %%            {len1,Len1},{lensize,LenSize},{len2,Len2},{len3,Len3},
                    %%            {masked,Masked},{mask,Mask}]]),
                    Payload = case Masked of
                                  0 -> Payload0;
                                  1 -> unmask(Payload0, Mask)
                              end,
                    D2 = reframe(Fin, Rsv1, operation(Opcode), Payload,
                                 D#data{buffer=(<<>>)}),
                    parse(Rest3, D2); % keep parsing
                true ->
                    D#data{buffer=Rest2}
            end;
        _ ->
            D#data{buffer=Rest1}
    end.

unmask(Bin, Mask) ->
    unmask(Bin, Mask, 0, <<>>).

unmask(<<>>, _Mask, _I, Y) ->
    Y;

unmask(<<X:8,A/binary>>, Mask, I, B) ->
    Y = X bxor binary:at(Mask, I rem 4),
    unmask(A, Mask, I+1, <<B/binary,Y:8>>).

%%% Args: Fin, OpAtom, Payload, #data{}

reframe(1, _, continuation, Payload, D) ->
    %% frame is at the end of fragments
    case D#data.queue of
        %% if frame is the end there must be previous fragments in the queue
        [] -> error(badstate);
        [[]|_] -> error(badstate);
        [L0|Q] ->
            %% pop fragments off the queue
            [{Op,Rsv1}|L] = reverse([Payload|L0]),
            relay_frame(Rsv1, Op, iolist_to_binary(L), D#data{queue=Q})
    end;

reframe(1, Rsv1, Op, Payload, D) ->
    %% frame is both the alpha and the 0MEGA!
    relay_frame(Rsv1, Op, Payload, D);

reframe(0, _, continuation, Payload, D) ->
    %% frame is in the middle of a stream of fragments
    case D#data.queue of
        %% if frame is in the middle there must be previous fragments in the
        %% queue
        [] -> error(badstate);
        [[]|_] -> error(badstate);
        [L0|Q] ->
            L = [Payload|L0],
            D#data{queue=[L|Q]}
    end;

reframe(0, Rsv1, Op, Payload, #data{queue=Q}=D) ->
    %% this frame is the beginning of fragments
    %% push a new list to the front of the list queue
    %% the list is in reverse, so op atom goes last
    L = [Payload,{Op,Rsv1}],
    D#data{queue=[L|Q]}.

operation(0) -> continuation;
operation(1) -> text;
operation(2) -> binary;
operation(8) -> close;
operation(9) -> ping;
operation(10) -> pong.

relay_frame(Rsv1, Op, Payload0, D) ->
    Payload = case {Rsv1,D#data.z} of
                  {1,null} ->
                      %% compression used but not negotiated!
                      Payload0;
                  {1,Z} ->
                      inflate(Z, Payload0);
                  {0,_} ->
                      Payload0
              end,
    case Op of
        close ->
            L = case Payload of
                    <<>> ->
                        [];
                    <<Code:16>> ->
                        [Code];
                    <<Code:16,Reason/utf8>> ->
                        [Code,Reason]
                end,
            relay({Op,L}, D);
        _ ->
            relay({Op,Payload}, D)
    end,
    D.

inflate(Z, Bin0) ->
    %% These extra octets are always the same and so removed/appended.
    Bin = <<Bin0/binary,0,0,255,255>>,
    %% TODO: idk what to do if it "needs" some "dict"
    zlib:inflate(Z, Bin, [{exception_on_need_dict,true}]).
    %% I believe future messages depend on previous message state.
    %%zlib:inflateReset(Z).
