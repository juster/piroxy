%%% inbound
%%% Provides a common interface for gen_server modules to implement for inbound
%%% connections. These connections send out requests and receive responses.
%%%

-module(inbound).
-include("phttp.hrl").

-export([close/2, reset/2, abort/3, send/3, send/4, request/3, respond/3]).

%%% external interface

%% called by outbound to signal the end of a response
close(Pid, Ref) ->
    gen_server:cast(Pid, {close, Ref}).

%% called by outbound to signal failure in the middle of a response
reset(Pid, Ref) ->
    gen_server:cast(Pid, {reset, Ref}).

%% i forget??
abort(Pid, Ref, Reason) ->
    gen_server:cast(Pid, {abort, Ref, Reason}).

%% called by client or user agent creating requests
send(Pid, HostInfo, Head) ->
    send(Pid, HostInfo, Head, ?EMPTY).

send(Pid, HostInfo, Head, Body) ->
    gen_server:call(Pid, {send, HostInfo, Head, Body}).

%% called by outbound to fetch the body of the request
request(Pid, Ref, Request) ->
    gen_server:call(Pid, {request, Ref, Request}).

%% called by outbound to stream the response to a request
respond(Pid, Ref, Response) ->
    gen_server:cast(Pid, {respond, Ref, Response}).
