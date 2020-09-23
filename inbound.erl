%%% inbound
%%% Provides a common interface for gen_server modules to implement for inbound
%%% connections. These connections send out requests and receive responses.
%%%

-module(inbound).
-include("phttp.hrl").

-export([close/2, reset/2, fail/3, new/3]).
-export([request_body/2, respond/3]).

%%% external interface

%% called by outbound to signal the end of a response
close(Pid, Ref) ->
    gen_server:cast(Pid, {close, Ref}).

%% called by outbound to signal failure in the middle of a response
reset(Pid, Ref) ->
    gen_server:cast(Pid, {reset, Ref}).

%% called by request_manager to indicate total failure
fail(Pid, Ref, Reason) ->
    gen_server:cast(Pid, {fail, Ref, Reason}).

%% called by client or user agent creating requests
new(Pid, HostInfo, Head) ->
    gen_server:call(Pid, {new, HostInfo, Head}).

%send(Pid, HostInfo, Head, Body) ->
%    gen_server:call(Pid, {send, HostInfo, Head, Body}).

%% called by outbound to fetch the body of the request
%% returns:
%%  {some,iolist()} to signal there are more chunks coming
%%  {last,iolist()} to signal this is the last chunk of body
request_body(Pid, Ref) ->
    gen_server:call(Pid, {request_body, Ref}).

%% called by outbound to stream the response to a request
respond(Pid, Ref, Response) ->
    gen_server:cast(Pid, {respond, Ref, Response}).
