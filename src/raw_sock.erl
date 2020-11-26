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
    receive
        {hello,client,Pid1} ->
            receive
                {hello,server,Pid2} ->
                    Pid2 ! ready,
                    Pid1 ! ready,
                    mitm_loop(Pid1, Pid2, Id)
            end
    end.

mitm_loop(Pid1, Pid2, Id) ->
    mitm_loop(Pid1, Pid2, Id, 1).

mitm_loop(Pid1, Pid2, Id, I) ->
    receive
        {raw_pipe,Pid1,Bin} ->
            pievents:send([I|Id], raw, Bin),
            Pid2 ! {raw_pipe,Bin},
            mitm_loop(Pid1, Pid2, Id, I+1);
        {raw_pipe,Pid2,Bin} ->
            pievents:send([I|Id], raw, Bin),
            Pid1 ! {raw_pipe,Bin},
            mitm_loop(Pid1, Pid2, Id, I+1)
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
    link(Pid),
    Pid ! {hello,Role,self()},
    receive
        {upgrade,Sock,Bin} ->
            loop(Pid, Sock, Bin)
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
        {tcp,_,Bin} ->
            Pid ! {raw_pipe,self(),Bin},
            loop(Pid, Sock);
        {ssl,_,Bin} ->
            Pid ! {raw_pipe,self(),Bin},
            loop(Pid, Sock);
        {tcp_error,Sock,Rsn} ->
            Pid ! {raw_pipe,self(),{error,Rsn}},
            shutdown(Pid,Sock);
        {ssl_error,Sock,Rsn} ->
            Pid ! {raw_pipe,self(),{error,Rsn}},
            shutdown(Pid,Sock);
        {tcp_closed,_} ->
            Pid ! {raw_pipe,self(),eof},
            shutdown(Pid,Sock);
        {ssl_closed,_} ->
            Pid ! {raw_pipe,self(),eof},
            shutdown(Pid,Sock);
        {raw_pipe,eof} ->
            shutdown(Pid,Sock);
        {raw_pipe,{error,_}} ->
            shutdown(Pid,Sock);
        {raw_pipe,exit} ->
            ?LOG_WARNING("raw_sock ~p received {raw_pipe,exit} inside main loop",
                         [self()]),
            pisock:close(Sock),
            ok;
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
            loop(Pid, Sock)
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
    receive
        {tcp,_,Bin} ->
            Pid ! {raw_pipe,Bin},
            cleanup(Pid,Sock);
        {ssl,_,Bin} ->
            Pid ! {raw_pipe,Bin},
            cleanup(Pid,Sock);
        {tcp_closed,_} ->
            Pid ! {raw_pipe,exit},
            ok;
        {ssl_closed,_} ->
            Pid ! {raw_pipe,exit},
            ok;
        {raw_pipe,exit} ->
            pisock:close(Sock),
            ok;
        {raw_pipe,_} ->
            cleanup(Pid,Sock);
        {A,_,Rsn} when A == tcp_error; A == ssl_error ->
            ?LOG_ERROR("raw_sock ~s: ~p", [A, Rsn]),
            exit(Rsn);
        {A,_} when A == tcp_closed; A == ssl_closed ->
            Pid ! {raw_pipe,exit},
            ok;
        Any ->
            ?LOG_ERROR("raw_sock received unknown message: ~p", [Any]),
            error(internal)
    end.
