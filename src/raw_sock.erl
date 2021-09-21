-module(raw_sock).
-export([start_link/1,init/1,handshake/2,binary_to/2,relay_binary/2]).
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
            loop(#state{socket=Sock,buffer=Buf})
    end.

handshake(Pid1,Pid2) ->
    Pid1 ! {handshake,binary,Pid2}.

binary_to(Pid1,L) ->
    Pid1 ! {binary_to,L},
    ok.

relay_binary(Pid,Any) ->
    Pid ! {binary,Any}.

%%%
%%% INTERNAL
%%%

loop(State0) ->
    receive
        Any ->
            loop(handle(Any, State0))
    end.

handle({handshake,binary,Pid2},S) ->
    binary_to(Pid2,self()),
    S;

handle({handshake,_,_},S) ->
    S;

handle({binary_to,L},#state{relay=undefined} = S) ->
    #state{socket=Sock,buffer=Buf} = S,
    lists:foreach(fun (Pid) ->
                          relay_binary(Pid,Buf),
                          link(Pid)
                  end,L),
    ok = pisock_lib:set_opts(Sock,[{active,true}]),
    S#state{relay=L,buffer=undefined};

handle({binary_to,L},_) ->
    ?LOG_ERROR("raw_sock: attempt to set relay twice"),
    lists:foreach(fun (Pid) -> exit(Pid,kill) end, L),
    exit(badlogic);

handle({binary,Bin},#state{socket=Sock} = S)
  when is_binary(Bin) ->
    pisock_lib:send(Sock,Bin),
    S;

handle({binary,_},_) ->
    exit(badarg);

handle(closed,#state{relay=Pid,socket=Sock}) ->
    pisock_lib:close(Sock),
    case Pid of
        undefined ->
            ok;
        _ ->
            Pid ! closed
    end,
    exit(normal);

handle({X,_,_},#state{relay=undefined}) when X == tcp; X == ssl ->
    %% socket should not be active until a relay is provided!
    exit(badlogic);

handle({X,_,Bin},#state{relay=L} = S) when X == tcp; X == ssl ->
    lists:foreach(fun (Pid) -> relay_binary(Pid,Bin) end, L),
    S;

handle({X,_,Rsn},#state{socket=Sock}) when X == tcp_error; X == ssl_error ->
    ?LOG_ERROR("raw_sock ~s: ~p", [X,Rsn]),
    pisock_lib:close(Sock),
    exit({X,Rsn});

handle({X,_},_) when X == tcp_closed; X == ssl_closed ->
    exit(closed).
