-module(raw_stream).
-export([start_link/1, read/2, push/3, shutdown/2]).
-export([middleman/0]).

middleman() ->
    receive
        {checkin,Pid1} ->
            receive
                {checkin,Pid2} ->
                    Pid1 ! {link,Pid2},
                    Pid2 ! {link,Pid1}
            end
    end.

start_link([MMPid]) ->
    start_link([MMPid, empty]);

start_link([MMPid, Bin]) ->
    MMPid ! {checkin,self()},
    receive
        {link,Pid} ->
            link(Pid),
            case Bin of
                empty -> ok;
                <<>> -> ok;
                _ -> Pid ! {stream,Bin}
            end,
            {ok,Pid}
    after 10000 ->
              error(timeout)
    end.

read(Pid, Bin) ->
    Pid ! {stream,Bin},
    ok.

push(_, {tcp,Sock}, Bin) ->
    gen_tcp:send(Sock, Bin);

push(_, {ssl,Sock}, Bin) ->
    ssl:send(Sock, Bin).

shutdown(Pid, Reason) ->
    exit(Pid, Reason).
