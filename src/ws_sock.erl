-module(ws_sock).
-behavior(gen_statem).
-include_lib("kernel/include/logger.hrl").
-import(lists, [reverse/1]).

-record(data, {pid,role,socket,buffer=(<<>>),queue=[],z=null}).

-export([start_mitm/1, mitm_loop/1, start_client/3, start_server/3, ready/1]).
-export([init/1, callback_mode/0, startup/3, connected/3, frames/3,
         cleanup/3]).

%%%
%%% MIDDLEMAN PROCESS
%%%

start_mitm(Id) ->
    spawn(?MODULE, mitm_loop, [Id]).

mitm_loop(Id) ->
    receive
        {hello,client,Pid1} ->
            receive
                {hello,server,Pid2} ->
                    ready(Pid1),
                    ready(Pid2),
                    mitm_loop(Pid1, Pid2, Id, 1)
            after 5000 ->
                      exit(timeout)
            end
    after 5000 ->
              exit(timeout)
    end.

mitm_loop(Pid1, Pid2, Id, I) ->
    receive
        {ws_pipe,Pid1,Bin} ->
            gen_statem:cast(Pid2, {ws_pipe,Bin}),
            mitm_loop(Pid1, Pid2, Id, I);
        {ws_pipe,Pid2,Bin} ->
            gen_statem:cast(Pid1, {ws_pipe,Bin}),
            mitm_loop(Pid1, Pid2, Id, I);
        {ws_log,Pid1,Term} ->
            %% receive from the sending proc
            io:format("*DBG* ws_sock send: ~p~n", [Term]),
            piroxy_events:send([I|Id], ws, Term),
            mitm_loop(Pid1, Pid2, Id, I+1);
        {ws_log,Pid2,Term} ->
            %% receive from the receiving proc
            io:format("*DBG* ws_sock recv: ~p~n", [Term]),
            piroxy_events:recv([I|Id], ws, Term),
            mitm_loop(Pid1, Pid2, Id, I+1);
        {ws_close,Pid1} ->
            io:format("*DBG* ws_sock send ws_close~n"),
            gen_statem:cast(Pid2, ws_close),
            mitm_loop(Pid1, Pid2, Id, I);
        {ws_close,Pid2} ->
            io:format("*DBG* ws_sock recv ws_close~n"),
            gen_statem:cast(Pid1, ws_close),
            mitm_loop(Pid1, Pid2, Id, I);
        Any ->
            io:format("*DBG* ws_sock:mitm_loop received unknown msg: ~p~n", [Any]),
            mitm_loop(Pid1, Pid2, Id, I)
    end.

%%%
%%% STATEMACHINE EXPORTS
%%%

start_client(Socket, Bin, Opts) ->
    start(Socket, Bin, Opts, client).

start_server(Socket, Bin, Opts) ->
    start(Socket, Bin, Opts, server).

start(Socket, Bin, [MitmPid,Exts], Role) ->
    case gen_statem:start(?MODULE, [MitmPid,Role,Exts], []) of
        {ok,Pid}=T ->
            pisock:setopts(Socket, [{active,false}]),
            pisock:control(Socket, Pid),
            upgrade(Pid, Socket, Bin),
            T;
        {error,_}=Err ->
            Err
    end.

ready(Pid) ->
    gen_statem:cast(Pid, ready).

%%%
%%% BEHAVIOR CALLBACKS
%%%

callback_mode() -> [state_functions].

init([Pid,Role,Exts]) ->
    io:format("*DBG* ws_sock: self=~p Exts=~p~n", [self(),Exts]),
    try
        link(Pid),
        Pid ! {hello,Role,self()},
        Z = case proplists:get_value(deflate, Exts, false) of
                true ->
                    X = zlib:open(),
                    %% XXX: An important (undocumented) feature of zlib is that
                    %% a negative window size tells it to NOT look for the zlib
                    %% header and CRC32 suffix!
                    zlib:inflateInit(X, -15),
                    X;
                false ->
                    null
            end,
        {ok, startup, #data{pid=Pid,role=Role,z=Z}}
    catch
        error:noproc:_ ->
            io:format("*DBG* failed to link to ~p~n", [Pid]),
            {stop,nproc}
    end.

startup(cast, {upgrade,Sock,Bin}, D) ->
    {next_state, connected,
     D#data{socket=Sock, buffer=Bin}};

startup(_, _, _D) ->
    {keep_state_and_data, postpone}.

connected(cast, ready, D) ->
    pisock:setopts(D#data.socket, [{active,true}]),
    {next_state, frames, D, {next_event,info,{tcp,null,<<>>}}};

connected(_, _, _D) ->
    {keep_state_and_data, postpone}.

frames(cast, ws_close, D) ->
    pisock:shutdown(D#data.socket, write),
    {next_state, cleanup, D};

frames(cast, {ws_pipe,Bin}, D) ->
    pisock:send(D#data.socket, Bin),
    keep_state_and_data;

frames(info, {A,_,Bin}, D)
  when A =:= tcp; A =:= ssl ->
    D#data.pid ! {ws_pipe,self(),Bin}, % relay bytes to the middleman
    {keep_state, parse(Bin, D)};

frames(info, {A,_}, D)
  when A =:= tcp_closed; A =:= ssl_closed ->
    D#data.pid ! {ws_close,self()},
    {stop,shutdown};

frames(info, {A,_,Reason}, _D)
  when A =:= tcp_error; A =:= ssl_error ->
    {stop,{A,Reason}}.

%%%
%%% In cleanup state we wait for the other end to send ws_close
%%% OR we send ws_close ourselves when the socket has closed.
%%%

cleanup(cast, ws_close, D) ->
    pisock:close(D#data.socket),
    io:format("*DBG* ws_close, closing ~p~n", [self()]),
    {stop,shutdown};

cleanup(cast, {ws_pipe,_}, _D) ->
    %% ignore any ws_pipe messages other than exit
    keep_state_and_data;

cleanup(info, {A,_,Reason}, _D)
  when A =:= tcp_error; A =:= ssl_error ->
    {stop,{A,Reason}};

cleanup(info, {A,_}, _D)
  when A =:= tcp_closed; A =:= ssl_closed ->
    io:format("*DBG* ~s, closing ~p~n", [A,self()]),
    {stop,shutdown};

%%% The reason we are in cleanup state is to make sure we receive all of the
%%% data before we shutdown.
cleanup(info, {A,_,Bin}, D)
  when A =:= tcp; A =:= ssl ->
    D#data.pid ! {ws_pipe,self(),Bin},
    {keep_state, parse(Bin, D)}.

%%%
%%% INTERNAL FUNCTIONS
%%%

upgrade(Pid, Sock, Bin) ->
    gen_statem:cast(Pid, {upgrade,Sock,Bin}).

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
                    parse(Rest3, frame(Fin, Rsv1, operation(Opcode), Payload,
                                       D#data{buffer=(<<>>)}));
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

frame(1, _, continuation, Payload, D) ->
    %% frame is at the end of fragments
    case D#data.queue of
        %% if frame is the end there must be previous fragments in the queue
        [] -> error(badstate);
        [[]|_] -> error(badstate);
        [L0|Q] ->
            %% pop fragments off the queue
            [{Op,Rsv1}|L] = reverse([Payload|L0]),
            log(Rsv1, Op, iolist_to_binary(L), D#data{queue=Q})
    end;

frame(1, Rsv1, Op, Payload, D) ->
    %% frame is both the alpha and the 0MEGA!
    log(Rsv1, Op, Payload, D);

frame(0, _, continuation, Payload, D) ->
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

frame(0, Rsv1, Op, Payload, #data{queue=Q}=D) ->
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

log(Rsv1, Op, Payload0, D) ->
    Payload = case {Rsv1,D#data.z} of
                  {1,null} ->
                      %% compression used but not negotiated!
                      Payload0;
                  {1,Z} ->
                      inflate(Z, Payload0);
                  {0,_} ->
                      Payload0
              end,
    D#data.pid ! {ws_log, self(), {Op,Payload}},
    case Op of
        close ->
            D#data.pid ! {ws_close,self()},
            pisock:shutdown(D#data.socket, write),
            throw({next_state, cleanup, D});
        _ ->
            D
    end.

inflate(Z, Bin0) ->
    %% These extra octets are always the same and so removed/appended.
    Bin = <<Bin0/binary,0,0,255,255>>,
    %% TODO: idk what to do if it "needs" some "dict"
    zlib:inflate(Z, Bin, [{exception_on_need_dict,true}]).
    %% I believe future messages depend on previous message state.
    %%zlib:inflateReset(Z).
