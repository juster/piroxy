-module(piroxy_events).
-export([start_link/0, connect/3, send/3, recv/3, cancel/2, fail/3]).

start_link() ->
    gen_event:start_link({local,?MODULE}).

%%% called by the inbound process

connect(Id, Proto, Target) ->
    gen_event:notify(?MODULE, {connect,Id,Proto,Target}).

send(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {send,Id,Proto,Term}).

recv(Id, Proto, Term) ->
    gen_event:notify(?MODULE, {recv,Id,Proto,Term}).

cancel(Id, Proto) ->
    gen_event:notify(?MODULE, {fail,Id,Proto,cancelled}).

fail(Id, Proto, Reason) ->
    gen_event:notify(?MODULE, {fail,Id,Proto,Reason}).
