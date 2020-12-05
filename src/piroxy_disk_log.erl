-module(piroxy_disk_log).
-behavior(gen_event).

-export([start_link/0, read/0, read/1, truncate/0]).
-export([watch/0]).
-export([init/1, handle_event/2, handle_call/2]).

%%%
%%% EXPORTS
%%%

start_link() ->
    try
        Pid = spawn_link(?MODULE, watch, []),
        {ok,Pid}
    catch
        exit:Rsn ->
            {error,Rsn}
    end.

read() ->
    gen_event:call(piroxy_events, ?MODULE, {read,start}).

read(Continuation) ->
    gen_event:call(piroxy_events, ?MODULE, {read,Continuation}).

truncate() ->
    gen_event:call(piroxy_events, ?MODULE, truncate).

watch() ->
    gen_event:add_sup_handler(piroxy_events, ?MODULE, []),
    loop().

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    Path = code:lib_dir(piroxy)++"/priv/log/events.log",
    case disk_log:open([{name,piroxy}, {file,Path}]) of
        {ok,Log} ->
            {ok,Log};
        {error,Rsn} ->
            {stop,Rsn}
    end.

handle_event(Event, Log) ->
    case disk_log:log(Log, Event) of
        ok ->
            {ok,Log};
        {error,Rsn} ->
            exit(Rsn)
    end.

handle_call({read,Etc}, Log) ->
    case disk_log:chunk(Log, Etc) of
        eof ->
            {ok, {ok,eof}, Log};
        {error,_} = Err ->
            {ok, Err, Log};
        {Etc2, Terms} ->
            {ok, {ok,{Terms,Etc2}}, Log}
    end;

handle_call(truncate, Log) ->
    {ok,disk_log:truncate(Log),Log}.

%%%
%%% INTERNALS
%%%

loop() ->
    receive
        {gen_event_EXIT,_,{swapped,_,_}} ->
            loop();
        {gen_event_EXIT,_,Rsn} ->
            exit(Rsn)
    end.
