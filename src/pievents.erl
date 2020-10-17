-module(pievents).

-export([start/0, start_link/0]).
-export([make_request/3, stream_request/2, fail_request/2, end_request/1,
         respond/2, close_response/1, upgrade_stream/3, make_tunnel/2]).

start() ->
    gen_event:start({local,?MODULE}).

start_link() ->
    gen_event:start_link({local,?MODULE}).

%%% called by the inbound process

make_request(Req, Head, HostInfo) ->
    gen_event:notify(?MODULE, {make_request,Req,Head,HostInfo}).

stream_request(Req, Body) ->
    gen_event:notify(?MODULE, {stream_request,Req,Body}).

fail_request(Req, Reason) ->
    gen_event:notify(?MODULE, {fail_request,Req,Reason}).

end_request(Req) ->
    gen_event:notify(?MODULE, {end_request,Req}).

respond(Req, Any) ->
    gen_event:notify(?MODULE, {respond,Req,Any}).

close_response(Req) ->
    gen_event:notify(?MODULE, {close_response,Req}).

upgrade_stream(Req, Stream, Args) ->
    gen_event:notify(?MODULE, {upgrade_stream,Req,Stream,Args}).

make_tunnel(Req, HostInfo) ->
    gen_event:notify(?MODULE, {make_tunnel,Req,HostInfo}).
