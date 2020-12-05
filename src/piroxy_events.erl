-module(piroxy_events).
-export([start_link/0, connect/3, send/3, recv/3, cancel/2, fail/3]).

start_link() ->
    gen_event:start_link({local,?MODULE}).

%%% called by the inbound process

connect(Id, Proto, Target) ->
    gen_event:notify(?MODULE, {connect,tstamp(),Id,Proto,Target}).

send(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {send,tstamp(),Id,Proto,Term}).

recv(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {recv,tstamp(),Id,Proto,Term}).

cancel(Id, Proto) ->
    gen_event:notify(?MODULE, {fail,tstamp(),Id,Proto,cancelled}).

fail(Id, Proto, Reason) ->
    gen_event:notify(?MODULE, {fail,tstamp(),Id,Proto,Reason}).

tstamp() ->
    DT = calendar:universal_time(),
    calendar:datetime_to_gregorian_seconds(DT).

