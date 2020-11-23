-module(raw_sock).
-include_lib("kernel/include/logger.hrl").

-export([start_mitm/0, middleman/0, start_server/3, start_client/4, loop/0]).

start_mitm() ->
    spawn(?MODULE, middleman, []).

middleman() ->
    receive
        {hello,Pid1} ->
            receive
                {hello,Pid2} ->
                    Pid2 ! {hello,Pid1},
                    Pid1 ! {hello,Pid2}
            end
    end.

start_server(Socket, Args, Opts) ->
    start(Socket, Args, Opts, <<>>).

start_client(Socket, Args, Opts, Bin) ->
    start(Socket, Args, Opts, Bin).

start(Socket, [Id, MitmPid], _Opts, Bin) ->
    Pid = spawn(?MODULE, loop, []),
    MitmPid ! {hello,Pid},
    pisock:setopts(Socket, [{active,false}]),
    case pisock:control(Socket, Pid) of
        ok ->
            Pid ! {upgrade,Id,Socket,Bin};
        {error,Rsn} ->
            error(Rsn)
    end,
    Pid.

loop() ->
    receive
        {hello,Pid} ->
            link(Pid),
            loop(Pid)
    end.

loop(Pid) ->
    receive
        {upgrade,Id2,Sock,Bin} ->
            %% Ensure that the fake binary message is received first.
            self() ! {tcp,null,Bin},
            pisock:setopts(Sock, [{active,true}]),
            loop(Pid, Id2, Sock)
    end.

loop(Pid, Id, Sock) ->
    receive
        {tcp,_,Bin} ->
            Pid ! {raw_pipe, Bin},
            loop(Pid, Id, Sock);
        {ssl,_,Bin} ->
            Pid ! {raw_pipe, Bin},
            loop(Pid, Id, Sock);
        {tcp_error,Sock,Rsn} ->
            Pid ! {raw_pipe,{error,Rsn}},
            Pid ! {raw_pipe,eof};
        {ssl_error,Sock,Rsn} ->
            Pid ! {raw_pipe,{error,Rsn}},
            Pid ! {raw_pipe,eof};
        {tcp_closed,_} ->
            Pid ! {raw_pipe,eof};
        {ssl_closed,_} ->
            Pid ! {raw_pipe,eof};
        {raw_pipe,eof} ->
            case pisock:shutdown(Sock, write) of
                ok ->
                    loop(Pid, Id, Sock);
                {error,Rsn} ->
                    ?LOG_ERROR("shutdown error: ~p", [Rsn]),
                    ok
            end;
        {raw_pipe,{error,_}} ->
            pisock:shutdown(Sock, read_write),
            loop(Pid, Id, Sock);
        {raw_pipe,Bin} ->
            case pisock:send(Sock, Bin) of
                ok ->
                    loop(Pid, Id, Sock);
                {error,_} = Err ->
                    Pid ! {raw_pipe,Err},
                    Pid ! {raw_pipe,eof},
                    case pisock:shutdown(Sock, write) of
                        ok ->
                            loop(Pid, Id, Sock);
                        {error,Rsn} ->
                            error(Rsn)
                    end
            end;
        {http_pipe,_,_} ->
            error(trailing_http_pipe);
        Any ->
            io:format("*DBG* received unexpected messages: ~p~n", [Any]),
            loop(Pid, Id, Sock)
    end.
