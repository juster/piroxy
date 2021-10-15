-module(piroxy_events).
-export([start_link/0,log/4,connect/3,send/3,recv/3,close/2,cancel/2,fail/3]).

start_link() ->
    gen_event:start_link({local,?MODULE}).

%%% called by the inbound process

log(Id,Proto,Atom,Term) ->
    gen_event:notify(?MODULE, {Id,Atom,tstamp(),Proto,Term}).

connect(Id,Proto,Target) ->
    log(Id,Proto,connect,Target).

send(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {Id,send,tstamp(),Proto,Term}).

recv(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {Id,recv,tstamp(),Proto,Term}).

close(Id, Proto) ->
    gen_event:notify(?MODULE, {Id,close,tstamp(),Proto,null}).

cancel(Id, Proto) ->
    gen_event:notify(?MODULE, {Id,fail,tstamp(),Proto,cancelled}).

fail(Id, Proto, Reason) ->
    gen_event:notify(?MODULE, {Id,fail,tstamp(),Proto,Reason}).

tstamp() ->
    erlang:monotonic_time() - erlang:system_info(start_time).
