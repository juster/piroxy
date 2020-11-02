-module(request_manager).
-behavior(gen_server).

-import(lists, [foreach/2, keyfind/3, keytake/3]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([make_request/3, cancel_request/1, pending_requests/0, targets/0]). % calls
-export([init/1, handle_cast/2, handle_call/3, handle_info/2]).

%%%
%%% EXPORTS
%%%

make_request(Req, Target, Head) ->
    gen_server:cast(?MODULE, {make_request,Req,Target,Head}).

cancel_request(Req) ->
    gen_server:cast(?MODULE, {cancel_request,Req}).

pending_requests() ->
    gen_server:call(?MODULE, pending_requests).

targets() ->
    gen_server:call(?MODULE, targets).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    process_flag(trap_exit, true),
    {ok, []}.

handle_cast({make_request,Req,Target,Head}, L) ->
    case keyfind(Target, 1, L) of
        {_,Pid} ->
            request_target:send_request(Pid, Req, Head),
            {noreply,L};
        false ->
            {ok,Pid} = request_target:start_link(Target),
            request_target:send_request(Pid, Req, Head),
            {noreply,[{Target,Pid}|L]}
    end;

%% cancel a request, but we do not know which host the request is for...
handle_cast({cancel_request,Req}, L) ->
    foreach(fun ({_,TargetPid}) ->
                    request_target:cancel_request(TargetPid, Req)
            end, L),
    morgue:forget(Req),
    {noreply,L};

handle_cast(_, State) ->
    {noreply,State}.

handle_call(pending_requests, _From, State) ->
    Fun = fun ({_,[]}) -> false; (_) -> true end,
    L = [{Target, request_target:pending_requests(Pid)}
         || {Target,Pid} <- State],
    Reqs = lists:sort(lists:filter(Fun, L)),
    {reply,Reqs,State};

handle_call(targets, _From, State) ->
    {reply,State,State}.

handle_info({'EXIT',Pid,_Reason}, L0) ->
    case keytake(Pid, 2, L0) of
        error ->
            {stop,{unknown_pid,Pid},L0};
        {value,_,L} ->
            {noreply,L}
    end;

handle_info({gen_event_EXIT,_,Reason}, L) ->
    case Reason of
        normal -> {noreply,L};
        {swapped,_,_} -> {noreply,L};
        shutdown -> {stop,shutdown,L};
        Reason -> {stop,Reason,L}
    end;

handle_info(_, L) ->
    {noreply,L}.
