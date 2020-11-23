-module(pisock).
-export([send/2, shutdown/2, setopts/2, control/2]).

send({tcp,Sock}, Data) ->
    gen_tcp:send(Sock, Data);

send({ssl,Sock}, Data) ->
    ssl:send(Sock, Data).

shutdown({tcp,Sock}, How) ->
    gen_tcp:shutdown(Sock, How);

shutdown({ssl,Sock}, How) ->
    ssl:shutdown(Sock, How).

setopts({tcp,Sock}, Opts) ->
    inet:setopts(Sock, Opts);

setopts({ssl,Sock}, Opts) ->
    ssl:setopts(Sock, Opts).

control({tcp,Sock}, Pid) ->
    inet:controlling_process(Sock, Pid);

control({ssl,Sock}, Pid) ->
    ssl:controlling_process(Sock, Pid).

