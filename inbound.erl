%%% inbound
%%% Provides a common interface for gen_server modules to implement for inbound
%%% connections. These connections send out requests and receive responses.
%%%

-module(inbound).
-include("phttp.hrl").

-export([close/2, reset/2, abort/3, send/3, send/4, request/3, respond/3]).

%%% external interface

close(Pid, Ref) ->
    gen_server:cast(Pid, {close, Ref}).

reset(Pid, Ref) ->
    gen_server:cast(Pid, {reset, Ref}).

abort(Pid, Ref, Reason) ->
    gen_server:cast(Pid, {abort, Ref, Reason}).

send(Pid, HostInfo, Head) ->
    send(Pid, HostInfo, Head, ?EMPTY).

send(Pid, HostInfo, Head, Body) ->
    gen_server:call(Pid, {send, HostInfo, Head, Body}).

request(Pid, Ref, Request) ->
    gen_server:call(Pid, {request, Ref, Request}).

respond(Pid, Ref, Response) ->
    gen_server:cast(Pid, {respond, Ref, Response}).
