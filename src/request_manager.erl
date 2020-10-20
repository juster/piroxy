-module(request_manager).
-behavior(gen_server).

-import(lists, [foreach/2, keyfind/3, keydelete/3]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([make_request/3]). % calls
-export([init/1, handle_cast/2, handle_call/3, handle_info/2]).

%%%
%%% EXPORTS
%%%

make_request(Req, Target, Head) ->
    gen_server:cast(?MODULE, {make_request,Req,Target,Head}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    ok = gen_event:add_sup_handler(pievents, request_handler, []),
    {ok, []}.

handle_cast({make_request,Req,Target,Head}, L) ->
    case keyfind(Target, 1, L) of
        {_,Pid} ->
            request_target:make_request(Pid, Req, Head),
            {noreply,L};
        false ->
            {ok,Pid} = request_target:start_link(Target),
            request_target:make_request(Pid, Req, Head),
            {noreply,[{Target,Pid}|L]}
    end;

%% cancel a request, remove it from the todo list.
handle_cast({cancel_request,Req}, L) ->
    case keyfind(Req, 1, L) of
        {_,Pid} ->
            request_target:cancel_request(Pid, Req);
        false ->
            ?LOG_WARNING("request_manager: cancel_request cannot find request (~p)",
                         [Req])
    end,
    {noreply,L};

handle_cast(_, State) ->
    {noreply,State}.

handle_call(_, _, State) ->
    {reply,ok,State}.

handle_info({'EXIT',Pid,_Reason}, L) ->
    {noreply,keydelete(Pid, 2, L)};

handle_info({gen_event_EXIT,_,Reason}, L) ->
    case Reason of
        normal -> {noreply,L};
        {swapped,_,_} -> {noreply,L};
        shutdown -> {stop,shutdown,L};
        Reason -> {stop,Reason,L}
    end;

handle_info(_, L) ->
    {noreply,L}.
