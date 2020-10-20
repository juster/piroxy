-module(response_handler).
-include("../include/phttp.hrl").
-import(lists, [foreach/2]).

-export([add_sup_handler/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2]).

add_sup_handler() ->
    gen_event:add_sup_handler(pievents, {?MODULE,make_ref()}, [self()]).

init([Pid]) ->
    {ok, {Pid, pipipe:new(), dict:new()}}.

handle_event({make_request,{Pid,I},_,_}, {Pid,P,D}) ->
    {ok, {Pid, pipipe:push(I, P), dict:store(I, [], D)}};

handle_event({respond,{Pid,I},Resp}, {Pid,P,D}) ->
    {ok, {Pid, P, dict:append(I, {respond,Resp}, D)}};

handle_event({fail_request,{Pid,I},Reason}, {Pid,P0,D0}) ->
    {P,D} = write_last(I, {respond,{error,Reason}}, P0, D0),
    {ok, flush(Pid, P, D)};

handle_event({close_response,{Pid,I}}, {Pid,P,D}) ->
    {ok, flush(Pid, pipipe:close(I, P), D)};

handle_event({upgrade_stream,{Pid,I},M,A}, {Pid,P0,D0}) ->
    {P,D} = write_last(I, {upgrade_stream,M,A}, P0, D0),
    {ok, flush(Pid, P, D)};

handle_event({make_tunnel,{Pid,I},HostInfo}, {Pid,P0,D0}) ->
    {P,D} = write_last(I, {make_tunnel,HostInfo}, P0, D0),
    {ok, flush(Pid, P, D)};

handle_event(_, State) ->
    {ok, State}.

handle_call(_, State) ->
    {ok, ok, State}.

handle_info(_, State) ->
    {ok, State}.

write_last(X, Y, P0, D0) ->
    D = dict:append(X, Y, D0),
    P = pipipe:close(X, P0),
    {P,D}.

flush(Pid, P0, D0) ->
    case pipipe:pop(P0) of
        not_done ->
            {Pid,P0,D0};
        {X,P} ->
            {L,D} = dict:take(X, D0),
            foreach(fun (Any) -> Pid ! Any end, L),
            flush(Pid, P, D)
    end.
