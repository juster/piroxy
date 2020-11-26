-module(raw_sock).
-include_lib("kernel/include/logger.hrl").

-export([start_mitm/1, mitm_loop/1, start_server/3, start_client/3, loop/1]).

%%%
%%% Middleman process between two raw_sock processes.
%%% Handles the message counter and event generation.
%%%

start_mitm(Id) ->
    spawn(?MODULE, mitm_loop, [Id]).

mitm_loop(Id) ->
    io:format("spawned mitm_loop ~p~n", [self()]),
    process_flag(trap_exit, true),
    receive
        {hello,client,Pid1} ->
            receive
                {hello,server,Pid2} ->
                    Pid1 ! ready,
                    Pid2 ! ready,
                    mitm_loop(Pid1, Pid2, Id)
            end
    end.

mitm_loop(Pid1, Pid2, Id) ->
    mitm_loop(Pid1, Pid2, Id, 1).

mitm_loop(Pid1, Pid2, Id, I) ->
    receive
        {raw_pipe,Pid1,Bin} ->
            piroxy_events:send([I|Id], raw, Bin),
            Pid2 ! {raw_pipe,Bin},
            mitm_loop(Pid1, Pid2, Id, I+1);
        {raw_pipe,Pid2,Bin} ->
            piroxy_events:send([I|Id], raw, Bin),
            Pid1 ! {raw_pipe,Bin},
            mitm_loop(Pid1, Pid2, Id, I+1);
        {'EXIT',Pid1,normal} ->
            mitm_teardown(Pid2, Id, I);
        {'EXIT',Pid2,normal} ->
            mitm_teardown(Pid1, Id, I);
        {'EXIT',_,Rsn} ->
            exit(Rsn)
    end.

mitm_teardown(Pid, Id, I) ->
    io:format("*DBG* raw_sock mitm_teardown~n"),
    receive
        {raw_pipe,Pid,Bin} ->
            piroxy_events:send([I|Id], raw, Bin),
            mitm_teardown(Pid, Id, I+1);
        {'EXIT',_,Rsn} ->
            exit(Rsn)
    end.

%%%
%%% raw_sock socket handler process
%%%

start_server(Socket, Bin, Opts) ->
    start(Socket, Bin, Opts, server).

start_client(Socket, Bin, Opts) ->
    start(Socket, Bin, Opts, client).

start(Socket, Bin, [MitmPid], Role) ->
    Pid = spawn(?MODULE, loop, [[MitmPid,Role]]),
    pisock:setopts(Socket, [{active,false}]),
    case pisock:control(Socket, Pid) of
        ok ->
            Pid ! {upgrade,Socket,Bin},
            {ok,Pid};
        {error,_} = Err ->
            exit(Pid, kill),
            Err
    end.

loop([Pid, Role]) ->
    io:format("*DBG* spawned raw_sock ~p~n", [self()]),
    link(Pid),
    Pid ! {hello,Role,self()},
    receive
        {upgrade,Sock,Bin} ->
            loop(Pid,Sock,Bin)
    end.

loop(Pid,Sock,Bin) ->
    receive
        ready ->
            %% Ensure that the fake binary message is received first.
            self() ! {tcp,null,Bin},
            pisock:setopts(Sock, [{active,true}]),
            loop(Pid, Sock)
    end.

loop(Pid,Sock) ->
    receive
        {A,_,Bin} when A == tcp; A == ssl ->
            Pid ! {raw_pipe,self(),Bin},
            loop(Pid, Sock);
        {A,_,Rsn} when A == tcp_error; A == ssl_error ->
            ?LOG_ERROR("raw_sock ~s: ~p", [A,Rsn]),
            Pid ! {raw_pipe,self(),exit},
            shutdown(Pid,Sock);
        {A,_} when A == tcp_closed; A == ssl_closed ->
            Pid ! {raw_pipe,self(),exit},
            shutdown(Pid,Sock);
        {raw_pipe,exit} ->
            shutdown(Pid,Sock);
        {raw_pipe,Bin} when is_binary(Bin) ->
            case pisock:send(Sock,Bin) of
                ok ->
                    loop(Pid,Sock);
                {error,_} = Err ->
                    Pid ! {raw_pipe,Err}
            end;
        {http_pipe,_,_} = Msg ->
            ?LOG_ERROR("trailing http_pipe message to raw_sock (~p): ~p~n",
                       [self(),Msg]),
            error(trailing_http_pipe);
        Any ->
            io:format("*DBG* received unexpected messages: ~p~n", [Any]),
            error(internal)
    end.

shutdown(Pid,Sock) ->
    case pisock:shutdown(Sock, write) of
        ok ->
            cleanup(Pid,Sock);
        {error,closed} ->
            Pid ! {raw_pipe,exit},
            exit(closed);
        {error,Rsn} ->
            exit(Rsn)
    end.

cleanup(Pid,Sock) ->
    io:format("*DBG* raw_sock:cleanup~n"),
    receive
        {tcp,_,Bin} ->
            Pid ! {raw_pipe,Bin},
            cleanup(Pid,Sock);
        {ssl,_,Bin} ->
            Pid ! {raw_pipe,Bin},
            cleanup(Pid,Sock);
        {tcp_closed,_} ->
            exit(shutdown);
        {ssl_closed,_} ->
            exit(shutdown);
        {raw_pipe,exit} ->
            pisock:close(Sock),
            exit(shutdown);
        {raw_pipe,_} ->
            cleanup(Pid,Sock);
        {A,_,Rsn} when A == tcp_error; A == ssl_error ->
            ?LOG_ERROR("raw_sock ~s: ~p", [A, Rsn]),
            exit(Rsn);
        {A,_} when A == tcp_closed; A == ssl_closed ->
            Pid ! {raw_pipe,exit},
            exit(shutdown);
        Any ->
            ?LOG_ERROR("raw_sock received unknown message: ~p", [Any]),
            error(internal)
    end.
