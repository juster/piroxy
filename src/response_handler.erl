-module(response_handler).
-include("../include/phttp.hrl").

-export([add_sup_handler/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2]).

add_sup_handler() ->
    gen_event:add_sup_handler(pievents, {?MODULE,make_ref()}, [self()]).

init([Pid]) ->
    Fun = fun (L) ->
                  lists:foreach(fun (T) -> Pid ! T end, L)
          end,
    {ok, {Pid, piqueue:new(Fun)}}.

handle_event({make_request,{Pid,I},_,_}, {Pid,Q}) ->
    {ok, {Pid, piqueue:expect(I, Q)}};

handle_event({respond,{Pid,I},Any}, {Pid,Q}) ->
    {ok, {Pid, piqueue:append(I, {respond,Any}, Q)}};

handle_event({fail_request,{Pid,I},Reason}, {Pid,Q0}) ->
    Q = piqueue:append(I, {respond,{error,Reason}}, Q0),
    {ok, {Pid, piqueue:finish(I, Q)}};

handle_event({close_response,{Pid,I}}, {Pid,Q}) ->
    ?DBG("close_response", []),
    {ok, {Pid, piqueue:finish(I, Q)}};

handle_event({upgrade_stream,{Pid,I},M,A}, {Pid,Q0}) ->
    Q = piqueue:append(I, {upgrade,M,A}, Q0),
    {ok, {Pid, piqueue:finish(I, Q)}};

handle_event({make_tunnel,{Pid,I},HostInfo}, {Pid,Q0}) ->
    Q = piqueue:append(I, {make_tunnel,HostInfo}, Q0),
    {ok, {Pid, piqueue:finish(I, Q)}};

handle_event(_, State) ->
    {ok, State}.

handle_call(_, State) ->
    {ok, ok, State}.

handle_info(_, State) ->
    {ok, State}.

