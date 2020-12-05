-module(piroxy_disk_log).
-behavior(gen_event).

-export([start_link/0, enable/0, disable/0, watcher/0]).
-export([read/0, read/1, truncate/0]).
-export([init/1, handle_event/2, handle_call/2]).

%%%
%%% EXPORTS
%%%

start_link() ->
    case whereis(?MODULE) of
        undefined ->
            try
                Pid = spawn_link(?MODULE, watcher, []),
                register(?MODULE, Pid),
                {ok,Pid}
            catch
                exit:Rsn -> {error,Rsn}
            end;
        _ ->
            {error,already_started}
    end.

watcher() ->
    loop(off).

enable() ->
    ?MODULE ! enable,
    ok.

disable() ->
    ?MODULE ! disable,
    ok.

read() ->
    gen_event:call(piroxy_events, ?MODULE, {read,start}).

read(Continuation) ->
    gen_event:call(piroxy_events, ?MODULE, {read,Continuation}).

truncate() ->
    gen_event:call(piroxy_events, ?MODULE, truncate).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    Path = code:lib_dir(piroxy)++"/priv/log/events.log",
    case disk_log:open([{name,piroxy}, {file,Path}]) of
        {ok,_Log} = T ->
            io:format("*DBG* opened log: ~p~n", [Path]),
            T;
        {error,Rsn} ->
            exit(Rsn)
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

loop(off) ->
    receive
        enable ->
            case gen_event:add_sup_handler(piroxy_events, ?MODULE, []) of
                ok ->
                    loop(on);
                {error,Rsn} ->
                    exit(Rsn);
                {'EXIT',Rsn} ->
                    exit(Rsn)
            end;
        disable ->
            loop(off);
        {gen_event_EXIT,_,Rsn} ->
            handler_exit(off, Rsn)
    end;

loop(on) ->
    receive
        enable ->
            %% the logger was already enabled
            io:format("*DBG* logged already enabled~n"),
            loop(on);
        disable ->
            case gen_event:delete_handler(piroxy_events, ?MODULE, []) of
                ok ->
                    loop(off);
                {error,Reason} ->
                    exit(Reason);
                {'EXIT',Reason} ->
                    exit(Reason)
            end;
        {gen_event_EXIT,_,Rsn} ->
            handler_exit(on, Rsn)
    end.

handler_exit(State, normal) ->
    %% gen_event:delete_handler/3 was called
    loop(State);

handler_exit(_State, shutdown) ->
    %% XXX: should we exit or let the handler exit alone?
    ok;

handler_exit(State, {swapped,_,_}) ->
    loop(State);

handler_exit(_State, Rsn) ->
    exit(Rsn).

