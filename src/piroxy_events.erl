-module(piroxy_events).
-export([start_link/0, connect/3, send/3, recv/3, cancel/2, fail/3]).

start_link() ->
    gen_event:start_link({local,?MODULE}).

%%% called by the inbound process

connect(Req, Proto, Target) ->
    gen_event:notify(?MODULE, {connect,Req,Proto,Target}).

send(Req, Proto, Term) ->
    gen_event:notify(?MODULE, {send,Req,Proto,Term}).

recv(Req, Proto, Term) ->
    gen_event:notify(?MODULE, {recv,Req,Proto,Term}).

cancel(Req, Proto) ->
    gen_event:notify(?MODULE, {fail,Req,Proto,cancelled}).

fail(Req, Proto, Reason) ->
    gen_event:notify(?MODULE, {fail,Req,Proto,Reason}).
