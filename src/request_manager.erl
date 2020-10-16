-module(request_manager).

-import(lists, [flatmap/2, reverse/1, foreach/2]).

-export([start/0]).
-export([make/3, close/1, cancel/1]).

start() ->
    gen_event:start({local,?MODULE}).

%%% called by the inbound process

make(Req, Head, HostInfo) ->
    gen_event:notify(?MODULE, {make_request,Req,Head,HostInfo}).

cancel(Req) ->
    gen_event:notify(?MODULE, {cancel_request,Req}).

close(Req) ->
    gen_event:notify(?MODULE, {close_request,Req}).
