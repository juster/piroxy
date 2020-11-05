-module(pipipe).
-export([start_link/1, expect/2, drip/3, reset/2]).
-export([start/3, loop/3]).

-include("../include/phttp.hrl").

start_link(Pid) ->
    spawn_link(?MODULE, start, [Pid, [], dict:new()]).

expect(Pid, Key) ->
    Pid ! {expect,Key}.

drip(Pid, Key, Val) ->
    Pid ! {drip,Key,Val}.

reset(Pid, Key) ->
    Pid ! {reset,Key}.

start(Pid, Q, Cache) ->
    link(Pid),
    loop(Pid, Q, Cache).

loop(Pid, Q, Cache) ->
    receive
        {expect,Key} ->
            loop(Pid, Q++[{Key,wait}], dict:store(Key, [], Cache));
        {drip,Key,eof} ->
            ?DBG("loop", [{pid,Pid},{q,Q},{drip,Key,eof}]),
            case Q of
                [{Key,_}|Q_] ->
                    %% Flush pipeline as much as possible if 'eof' is received.
                    flush(Pid, Q_, dict:erase(Key, Cache));
                _ ->
                    loop(Pid, lists:keyreplace(Key, 1, Q, {Key,done}), Cache)
            end;
        {drip,Key,Val} ->
            case Q of
                [{Key,_}|_] ->
                    %% Key is the front of the queue, so stream immediately.
                    Pid ! {pipe,Key,Val},
                    loop(Pid, Q, Cache);
                _ ->
                    %% Otherwise, save the value in the cache.
                    loop(Pid, Q, dict:append(Key, Val, Cache))
            end;
        {reset,Key} ->
            case Q of
                [{Key,_}|_] ->
                    %% Cannot reset because this is the next key in the queue.
                    %% We may have already started relaying 'drip' messages!
                    exit(reset);
                _ ->
                    Q_ = lists:keyreplace(Key, 1, Q, {Key,wait}),
                    Cache_ = dict:store(Key, [], Cache),
                    loop(Pid, Q_, Cache_)
            end
    end.

flush(Pid, [{Key,Val}|Q], Cache) ->
    lists:foreach(fun (Term) ->
                          Pid ! {pipe,Key,Term}
                  end, dict:fetch(Key, Cache)),
    case Val of
        done -> flush(Pid, Q, dict:erase(Key, Cache));
        wait -> loop(Pid, Q, dict:erase(Key, Cache))
    end;

flush(Pid, Q, Cache) ->
    loop(Pid, Q, Cache).
