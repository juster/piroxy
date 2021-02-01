-module(piroxy_events).
-export([start_link/0, connect/3, send/3, recv/3, cancel/2, fail/3]).

start_link() ->
    gen_event:start_link({local,?MODULE}).

%%% called by the inbound process

connect(Id, Proto, Target) ->
    gen_event:notify(?MODULE, {Id,connect,tstamp(),Proto,Target}).

send(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {Id,send,tstamp(),Proto,Term}).

recv(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {Id,recv,tstamp(),Proto,Term}).

cancel(Id, Proto) ->
    gen_event:notify(?MODULE, {Id,fail,tstamp(),Proto,cancelled}).

fail(Id, Proto, Reason) ->
    gen_event:notify(?MODULE, {Id,fail,tstamp(),Proto,Reason}).

tstamp() ->
    erlang:monotonic_time() - erlang:system_info(start_time).
