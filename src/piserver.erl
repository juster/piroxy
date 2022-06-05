-module(piserver).

-include_lib("kernel/include/logger.hrl").
-include("../include/pihttp_lib.hrl").
-export([start_link/2,stop/0,superserver/2,listen/1,superloop/1]).
-define(N_LISTENERS, 10).

start_link(Addr, Port) ->
    Pid = proc_lib:spawn_link(?MODULE, superserver, [Addr,Port]),
    register(piserver, Pid),
    {ok,Pid}.

stop() ->
    exit(whereis(piserver), stop),
    ok.

superserver(_Addr, Port) ->
    case gen_tcp:listen(Port, [inet,{active,false},binary]) of
        {ok,ListenSock} ->
            process_flag(trap_exit,true),
            lists:foreach(fun (_) -> spawn_link_listener(ListenSock) end,
                          lists:seq(1,?N_LISTENERS)),
            superloop(ListenSock);
        {error,Reason} ->
            error(Reason)
    end.

spawn_link_listener(ListenSock) ->
    proc_lib:spawn_link(?MODULE,listen,[ListenSock]).

superloop(ListenSock) ->
    receive
        {'EXIT',_,normal} ->
            spawn_link_listener(ListenSock),
            superloop(ListenSock);
        {'EXIT',_,Reason} ->
            exit(Reason);
        upgrade ->
            piserver:superloop(ListenSock)
    end.

listen(ListenSock) ->
    {ok,Pid} = http_req_sock:start(),
    case gen_tcp:accept(ListenSock) of
        {ok,Socket} ->
            case gen_tcp:controlling_process(Socket,Pid) of
                ok ->
                    http_req_sock:control(Pid,Socket),
                    ok;
                {error,Reason} ->
                    http_req_sock:stop(Pid),
                    exit(Reason)
            end;
        {error,Reason} ->
            http_req_sock:stop(Pid),
            exit(Reason)
    end.
