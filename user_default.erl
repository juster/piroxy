-module(user_default).
-export([target/1, target_state/1, restart/0]).

target(L) when is_list(L) ->
    target(list_to_binary(L));

target(Host) ->
    case {lists:keyfind({https,Host,443}, 1, request_manager:targets()),
          lists:keyfind({http,Host,80}, 1, request_manager:targets())} of
        {false,false} -> false;
        {false,{_,Pid}} -> Pid;
        {{_,Pid},false} -> Pid
    end.

target_state(Host) ->
    case target(Host) of
        false ->
            false;
        Pid ->
            sys:get_state(Pid)
    end.

restart() ->
    application:stop(piroxy),
    application:start(piroxy).
