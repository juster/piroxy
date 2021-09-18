-module(raw_sock).
-include_lib("kernel/include/logger.hrl").

-export([start/3, loop/1, handshake/2, relay/2]).

handshake(Pid, MFA) ->
    link(Pid),
    Pid ! {handshake,self(),MFA},
    receive
        {handshake,Pid,MFA2} ->
            MFA2
    end.

relay(Pid, Term) ->
    Pid ! {raw_sock,Term},
    ok.

%%%
%%% raw_sock socket handler process
%%%

start(Socket, Bin, Opts) ->
    Pid = spawn(?MODULE, loop, [Opts]),
    pisock_lib:setopts(Socket, [{active,false}]),
    case pisock_lib:controlling_process(Socket, Pid) of
        ok ->
            Pid ! {upgrade,Socket,Bin},
            {ok,Pid};
        {error,_} = Err ->
            exit(Pid, kill),
            Err
    end.

loop(Opts) ->
    io:format("*DBG* spawned raw_sock ~p~n", [self()]),
    Client = proplists:get_bool(client, Opts),
    Server = proplists:get_bool(server, Opts),
    Role = if
               Client -> client;
               Server -> server;
               true -> exit(badarg)
           end,
    MFA = {?MODULE,relay,[self()]}, % the MFA used to send us messages
    case proplists:get_value(handshake, Opts) of
        {M,F,A} ->
            %% Start the handshake ourselves.
            loop(Role, apply(M,F,A++[MFA]));
        undefined ->
            %% Wait to receive the handshake. This is send via the handshake/2
            %% exported fun
            receive
                {handshake,Pid2,MFA2} ->
                    Pid2 ! {handshake,self(),MFA},
                    loop(Role, MFA2)
            end
    end.

loop(Role,{M,F,A}=MFA) ->
    receive
        {upgrade,Sock,Bin} ->
            %% Ensure that the leftover binary is relayed
            apply(M, F, A++[Bin]),
            pisock_lib:setopts(Sock, [{active,true}]),
            loop(Role,MFA,Sock)
    end.

loop(Role,{M,F,A}=MFA,Sock) ->
    receive
        {X,_,Bin} when X == tcp; X == ssl ->
            apply(M, F, A++[Bin]),
            loop(Role,MFA,Sock);
        {X,_,Rsn} when X == tcp_error; X == ssl_error ->
            ?LOG_ERROR("raw_sock ~s: ~p", [A,Rsn]),
            apply(M, F, A++[exit]),
            shutdown(Role,MFA,Sock);
        {X,_} when X == tcp_closed; X == ssl_closed ->
            apply(M, F, A++[exit]),
            shutdown(Role,MFA,Sock);
        %% messages sent from relay/2
        {raw_sock,exit} ->
            shutdown(Role,MFA,Sock);
        {raw_sock,Bin} when is_binary(Bin) ->
            case pisock_lib:send(Sock,Bin) of
                ok ->
                    loop(Role,MFA,Sock);
                {error,Rsn} ->
                    exit(Rsn)
            end;
        {http_pipe,_,_} = Msg ->
            ?LOG_ERROR("trailing http_pipe message to raw_sock (~p): ~p~n",
                       [self(),Msg]),
            error(trailing_http_pipe);
        Any ->
            io:format("*DBG* received unexpected messages: ~p~n", [Any]),
            error(internal)
    end.

shutdown(Role,{M,F,A}=MFA,Sock) ->
    case pisock_lib:shutdown(Sock, write) of
        ok ->
            cleanup(Role,MFA,Sock);
        {error,closed} ->
            apply(M, F, A++[exit]),
            exit(closed);
        {error,Rsn} ->
            exit(Rsn)
    end.

cleanup(Role,{M,F,A}=MFA,Sock) ->
    io:format("*DBG* raw_sock:cleanup~n"),
    receive
        {X,_,Bin} when X == tcp; X == ssl ->
            apply(M, F, A++[Bin]),
            cleanup(Role,MFA,Sock);
        {tcp_closed,_} ->
            exit(shutdown);
        {ssl_closed,_} ->
            exit(shutdown);
        {raw_sock,exit} ->
            pisock_lib:close(Sock),
            exit(shutdown);
        {raw_sock,_} ->
            cleanup(Role,MFA,Sock);
        {X,_,Rsn} when X == tcp_error; X == ssl_error ->
            ?LOG_ERROR("raw_sock ~s: ~p", [X, Rsn]),
            exit(Rsn);
        {X,_} when X == tcp_closed; X == ssl_closed ->
            apply(M, F, A++[exit]),
            exit(shutdown);
        Any ->
            ?LOG_ERROR("raw_sock received unknown message: ~p", [Any]),
            error(internal)
    end.
