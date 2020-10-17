-module(piroxy_sup).
-behavior(supervisor).
-export([start/0, start_shell/1, start_link/1, init/1]).

start() ->
    spawn(fun() ->
                  supervisor:start_link({local,?MODULE}, ?MODULE, [])
          end).

start_shell(Args) ->
    case supervisor:start_link({local,?MODULE}, ?MODULE, Args) of
        {ok,Pid} ->
            unlink(Pid);
        {error,_} = Err ->
            Err
    end.

start_link(Args) ->
    supervisor:start_link({local,?MODULE}, ?MODULE, Args).

init(Opts) ->
    Port = proplists:get_value(port, Opts, 8888),
    Keyfile = proplists:get_value(keyfile, Opts),
    Cafile = proplists:get_value(cafile, Opts),
    Passwd = proplists:get_value(passwd, Opts),
    case lists:any(fun(undefined)-> true; (_) -> false end,
                   [Keyfile, Cafile, Passwd]) of
        true ->
            exit(badarg);
        false ->
            {ok, {{one_for_one, 3, 10},
                  [{forger,
                    {forger, start_link, [[{keyfile,Keyfile},{cafile,Cafile},
                                           {passwd,Passwd}]]},
                    permanent,
                    10000,
                    worker,
                    [forger]},
                   {morgue,
                    {morgue, start_link, []},
                    permanent,
                    10000,
                    worker,
                    [morgue]},
                   {piserver,
                    {piserver, start_link, [null, Port]},
                    permanent,
                    10000,
                    worker,
                    [piserver]},
                   {pievents,
                    {pievents, start_link, []},
                    permanent,
                    10000,
                    worker,
                    dynamic},
                   {request_handler_mon,
                    {request_handler_mon, start_link, []},
                    permanent,
                    10000,
                    worker,
                    [request_handler_mon]
                   }
                  ]}}
    end.
