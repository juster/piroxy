-module(ptrace).
-export([start/2, loop/2]).

start(Pid, Path) ->
    {ok,File} = file:open(Path, [write]),
    spawn_link(?MODULE, loop, [Pid, File]).

loop(Pid, File) ->
    case erlang:trace(Pid, true, [procs,set_on_spawn]) of
        1 ->
            loop(File);
        _ ->
            exit(badarg)
    end.

loop(File) ->
    receive
        {trace,Pid1,spawn,Pid2,MFA} ->
            io:fwrite(File, "*TRACE* ~s ~p spawn ~p~n******* ~p~n",
                      [tstamp(),Pid1,Pid2,MFA]),
            loop(File);
        {trace,Pid1,exit,Reason} ->
            io:fwrite(File, "*TRACE* ~s ~p exit: ~p~n",
                      [tstamp(),Pid1,Reason]),
            loop(File);
        _ ->
            loop(File)
    end.

tstamp() ->
    {_,{_H,M,S}} = calendar:local_time(),
    io_lib:format("~2..0B~2..0B", [M,S]).
