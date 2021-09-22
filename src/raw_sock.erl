-module(raw_sock).
-export([start_link/1,init/1,handshake/2,relay_binary/2,close/1]).
-record(state, {socket,relay=[],buffer=[]}).
-include_lib("kernel/include/logger.hrl").

%%%
%%% EXPORTS
%%%

start_link(Opts) ->
    case proplists:get_value(socket,Opts) of
        undefined ->
            exit(badarg);
        Sock ->
            pisock_lib:setopts(Sock,[{active,false}]),
            Pid = spawn_link(fun () -> init(Opts) end),
            case pisock_lib:controlling_process(Sock,Pid) of
                ok ->
                    {ok,Pid};
                Any ->
                    unlink(Pid),
                    exit(Pid,kill),
                    Any
            end
    end.

init(Opts) ->
    [Sock,Buf] = [proplists:get_value(A,Opts) || A <- [socket,buffer]],
    case lists:member(undefined,[Sock,Buf]) of
        true ->
            exit(badarg);
        false ->
            wait(#state{socket=Sock,buffer=Buf})
    end.

handshake(Pid1,Pid2) ->
    Pid1 ! {handshake,self(),Pid2},
    receive
        {handshake,Term} ->
            Term
    after 1000 ->
            {error,timeout}
    end.

relay_binary(Pid,Any) ->
    Pid ! {binary,Any}.

close(Pid) ->
    Pid ! {close,self()},
    receive
        closed ->
            ok
    after 1000 ->
            error(timeout)
    end.

%%%
%%% INTERNAL
%%%

wait(S) ->
    receive
        {handshake,Pid,RawPid} ->
            link(Pid),
            RawPid ! {hello,self(),[self()]},
            wait2(Pid,S);
        {hello,Pid,L} ->
            Pid ! {howdy,self(),[self()]},
            warmup(L,S)
    after 1000 ->
            exit(timeout)
    end.

wait2(Pid, S) ->
    receive
        {howdy,_RawPid,L} ->
            %% XXX: should I double-check that the Pid matches hello?
            Pid ! {handshake,ok},
            warmup(L,S)
    end.

warmup(L,S) ->
    #state{socket=Sock,buffer=Buf} = S,
    lists:foreach(fun (Pid) -> relay_binary(Pid,Buf) end, L),
    %% Switch the socket to active mode.
    ok = pisock_lib:set_opts(Sock,[{active,true}]),
    loop(S#state{relay=L,buffer=undefined}).

loop(State0) ->
    receive
        Any ->
            loop(handle(Any, State0))
    end.

handle({binary,Bin}, #state{socket=Sock} = S)
  when is_binary(Bin) ->
    pisock_lib:send(Sock,Bin),
    S;

handle({binary,_},_) ->
    exit(badarg);

handle({close,Reply}, S) ->
    %% XXX: tcp_closed/ssl_closed event should fire after this
    pisock_lib:close(S#state.socket),
    Reply ! closed,
    exit(closed);

handle({X,_,_},#state{relay=undefined}) when X == tcp; X == ssl ->
    %% socket should not be active until a relay is provided!
    exit(badlogic);

handle({X,_,Bin}, S) when X == tcp; X == ssl ->
    relay({binary,Bin}, S),
    S;

handle({X,_,Rsn},#state{socket=Sock}) when X == tcp_error; X == ssl_error ->
    ?LOG_ERROR("raw_sock ~s: ~p", [X,Rsn]),
    pisock_lib:close(Sock),
    exit({X,Rsn});

handle({X,_}, _) when X == tcp_closed; X == ssl_closed ->
    %% - for raw_sock pairs, the twin raw_sock is linked and exits.
    %% - for ws_sock pairs, the ws_sock which owns this raw_sock gets the
    %%   {'EXIT',Pid,closed} message.
    exit(closed).

relay(Term,S) ->
    lists:foreach(fun (Pid) -> Pid ! Term end, S#state.relay),
    ok.
