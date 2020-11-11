-module(pievents).
-export([start_link/0, connect/2, send/3, recv/3, cancel/2, fail/2]).

start_link() ->
    gen_event:start_link({local,?MODULE}).

%%% called by the inbound process

connect(Req, Target) ->
    gen_event:notify(?MODULE, {connect,Req,Target}).

send(Req, Proto, Term) ->
    gen_event:notify(?MODULE, {send,Req,Proto,Term}).

recv(Req, Proto, Term) ->
    gen_event:notify(?MODULE, {recv,Req,Proto,Term}).

cancel(Req, Reason) ->
    gen_event:notify(?MODULE, {cancel,Req,Reason}).

fail(Req, Reason) ->
    gen_event:notify(?MODULE, {fail,Req,Reason}).
