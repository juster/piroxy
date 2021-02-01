-module(piroxy_hijack_spy).
-behavior(gen_event).
-export([start_link/0]).

%% EXPORTS

start_link() ->
    {ok, spawn_link(?MODULE,watchman,[self()])}.

watchman(Pid) ->
    case gen_event:add_sup_handler(piroxy_events, ?MODULE, [Pid]) of
        ok ->
            receive
                {gen_event_EXIT,_,shutdown} ->
                    %% the whole app is presumably shutting down
                    ok;
                {gen_event_EXIT,_,Rsn} ->
                    exit(Rsn)
            end
    end.

%% GEN_EVENT BEHAVIOR

init([Pid]) ->
    {ok,Pid}.

handle_event(Event, Pid) ->

