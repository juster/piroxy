-module(request_handler).
-behavior(gen_event).

-import(lists, [flatmap/2, reverse/1, foreach/2]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([init/1, handle_event/2, handle_call/2, handle_info/2]).

%%%
%%% gen_event callbacks
%%%

init([]) ->
    {ok, []}.

%%% First: handle internal responses that do not create outbound requests.

handle_event({make_request,Req,<<"*">>,#head{method=options}}, State) ->
    pievents:respond(Req, {status,ok}),
    pievents:close_response(Req),
    {ok,State};

handle_event({make_request,Req,Target,#head{method=connect}}, State) ->
    pievents:make_tunnel(Req, Target),
    {ok,State};

handle_event({make_request,Req,Target,Head}, State) ->
    %% TODO: check for WebSocket/HTTP2 requests here and upgrade them!
    %% convert data types first so we can fail before opening a socket
    ?LOG_DEBUG("make_request ~p:~n~p~n~s", [Req, Target, Head#head.line]),
    request_manager:make_request(Req, Target, Head),
    {ok,State};

handle_event({stream_request,Req,Body}, State) ->
    morgue:append(Req, Body),
    {ok,State};

handle_event({end_request,Req}, State) ->
    morgue:append(Req, done),
    {ok,State};

%% cancel a request, remove it from the todo list.
handle_event({cancel_request,Req}, State) ->
    request_manager:cancel_request(Req),
    {ok,State};

handle_event(_, State) ->
    {ok,State}.

handle_call(_, State) ->
    {ok,ok,State}.

handle_info(_, State) ->
    {ok,State}.
