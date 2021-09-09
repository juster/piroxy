-module(piserver).

-include_lib("kernel/include/logger.hrl").
-include("../include/pihttp_lib.hrl").
-import(lists, [foreach/2]).

-export([start/2, start_link/2, stop/0, superserver/1, listen/2]).

start(Addr, Port) ->
    Pid = spawn(?MODULE, listen, [Addr,Port]),
    register(piserver, Pid),
    {ok,Pid}.

start_link(Addr, Port) ->
    Pid = spawn_link(?MODULE, listen, [Addr,Port]),
    register(piserver, Pid),
    {ok,Pid}.

stop() ->
    exit(whereis(piserver), stop),
    ok.

listen(_Addr, Port) ->
    case gen_tcp:listen(Port, [inet,{active,false},binary]) of
        {ok,Listen} ->
            superserver(Listen);
        {error,Reason} ->
            io:format("~p~n",[{error,Reason}]),
            exit(Reason)
    end.

superserver(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok,Socket} ->
            {ok,Pid} = http_req_sock:start(),
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    http_req_sock:control(Pid, Socket),
                    piserver:superserver(Listen);
                {error,Reason} ->
                    exit(Pid, kill),
                    exit(Reason)
            end,
            ok;
        {error,Reason} ->
            exit(Reason)
    end.
