-module(request_manager).
-behavior(gen_server).

-import(lists, [foreach/2, keyfind/3, keytake/3]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([nextid/0, make/3, cancel/1, pending/0, targets/0]). % calls
-export([init/1, handle_cast/2, handle_call/3, handle_info/2]).

%%%
%%% EXPORTS
%%%

nextid() ->
    gen_server:call(?MODULE, nextid).

make(Pid, Target, Head) ->
    gen_server:call(?MODULE, {make_request,Pid,Target,Head}).

cancel(Req) ->
    gen_server:cast(?MODULE, {cancel_request,Req}).

pending() ->
    gen_server:call(?MODULE, pending_requests).

targets() ->
    gen_server:call(?MODULE, targets).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    process_flag(trap_exit, true),
    {ok, {[],1}}.

%% cancel a request, but we do not know which host the request is for...
handle_cast({cancel_request,Req}, L) ->
    foreach(fun ({_,TargetPid}) ->
                    request_target:cancel(TargetPid, Req)
            end, L),
    morgue:forget(Req),
    {noreply,L};

handle_cast(_, State) ->
    {noreply,State}.

handle_call(nextid, _From, {L,I}) ->
    {reply,I,{L,I+1}};

handle_call({make_request,Pid1,Target,Head}, _From, {L,I}) ->
    %%?DBG("make_request", [{req,I},{target,element(2,Target)},
    %%                      {head,Head#head.line}]),
    pipipe:expect(Pid1, I),
    case keyfind(Target, 1, L) of
        {_,Pid2} ->
            request_target:send(Pid2, I, Head, Pid1),
            {reply, I, {L,I+1}};
        false ->
            {ok,Pid2} = request_target:start_link(Target),
            request_target:send(Pid2, I, Head, Pid1),
            {reply, I, {[{Target,Pid2}|L],I+1}}
    end;

handle_call(pending_requests, _From, {L1,_}=State) ->
    L2 = [{Target, request_target:pending(Pid)}
          || {Target,Pid} <- L1],
    Fun = fun ({_,[]}) -> false; (_) -> true end,
    Reqs = lists:sort(lists:filter(Fun, L2)),
    {reply,Reqs,State};

handle_call(targets, _From, {L,_}=State) ->
    {reply,L,State}.

handle_info({'EXIT',Pid,_Reason}, {L0,I}) ->
    case keytake(Pid, 2, L0) of
        error ->
            {stop,{unknown_pid,Pid},L0};
        {value,_,L} ->
            {noreply,{L,I}}
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
