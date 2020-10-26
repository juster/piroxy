-module(response_handler).
-include("../include/phttp.hrl").
-import(lists, [foreach/2]).

-export([add_sup_handler/0]).
-export([init/1, terminate/2, handle_event/2, handle_call/2, handle_info/2]).

add_sup_handler() ->
    gen_event:add_sup_handler(pievents, {?MODULE,make_ref()}, [self()]).

init([Pid]) ->
    {ok, {Pid, pipipe:new()}}.

terminate(_Reason, {Pid,P}) ->
    lists:foreach(fun (I) ->
                          request_manager:cancel_request({Pid,I})
                  end, pipipe:values(P)).

handle_event({make_request,{Pid,I},_,_}, {Pid,P}) ->
    {ok, {Pid, pipipe:push(I, P)}};

handle_event({respond,{Pid,I},Resp}, {Pid,P}) ->
    {ok, {Pid, pipipe:append(I, {respond,Resp}, P)}};

handle_event({fail_request,{Pid,I},Reason}, {Pid,P0}) ->
    P = write_last(I, {respond,{error,Reason}}, P0),
    {ok, {Pid, flush(Pid, P)}};

handle_event({close_response,{Pid,I}}, {Pid,P}) ->
    {ok, {Pid, flush(Pid, pipipe:close(I, P))}};

handle_event({upgrade_stream,{Pid,I},M,A}, {Pid,P0}) ->
    P = write_last(I, {upgrade_stream,M,A}, P0),
    {ok, {Pid, flush(Pid, P)}};

handle_event({make_tunnel,{Pid,I},HostInfo}, {Pid,P0}) ->
    P = write_last(I, {make_tunnel,HostInfo}, P0),
    {ok, {Pid, flush(Pid, P)}};

handle_event(_, State) ->
    {ok, State}.

handle_call(_, State) ->
    {ok, ok, State}.

handle_info(_, State) ->
    {ok, State}.

write_last(X, Y, P0) ->
    pipipe:close(X, pipipe:append(X, Y, P0)).

flush(Pid, P0) ->
    case pipipe:pop(P0) of
        not_done ->
            P0;
        {_X,Y,P} ->
            foreach(fun (Any) -> Pid ! Any end, Y),
            flush(Pid, P)
    end.
