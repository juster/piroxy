-module(inbound).
-behavior(gen_server).

-include("phttp.hrl").

-compile(export_all).

%%% external interface

close_request(Pid, ReqId) ->
    gen_server:cast(Pid, {close_request, ReqId}).

reset_request(Pid, ReqId) ->
    gen_server:cast(Pid, {reset_request, ReqId}).

response_head(Pid, ReqId, Status, Headers) ->
    gen_server:cast(Pid, {response_head, ReqId, Status, Headers}).

abort_request(Pid, ReqId, Reason) ->
    gen_server:cast(Pid, {abort_request, ReqId, Reason}).

%%% gen_server behavior callbacks

init([]) ->
    ReqTab = ets:new(requests, [set,private]),
    {ReqTab}.

handle_cast({close_request, ReqId}, {ReqTab}) ->
    .
