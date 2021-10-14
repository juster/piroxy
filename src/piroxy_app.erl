-module(piroxy_app).
-export([start/2, stop/1]).

start(_Type, []) ->
    {ok,Cafile} = application:get_env(cafile),
    {ok,Keyfile} = application:get_env(keyfile),
    {ok,Passwd} = application:get_env(passwd),
    {ok,Pid} = piroxy_sup:start_link([{cafile,Cafile},{keyfile,Keyfile},
                                      {passwd,Passwd}]),
    {ok,Pid}.

stop(_State) ->
    ok.

