-module(request_manager).
-behavior(gen_server).

-import(lists, [foreach/2, keyfind/3, keytake/3]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([connect/3, cancel/1, pending/0, targets/0]). % calls
-export([init/1, handle_cast/2, handle_call/3, handle_info/2]).

%%%
%%% EXPORTS
%%%

connect(Req, Proto, Target) ->
    gen_server:cast(?MODULE, {connect,Req,Proto,Target}).

cancel(Req) ->
    gen_server:cast(?MODULE, {cancel,Req}).

pending() ->
    gen_server:call(?MODULE, pending_requests).

targets() ->
    gen_server:call(?MODULE, targets).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    process_flag(trap_exit, true),
    {ok, []}.

handle_cast({connect,Req,http,Target}, L) ->
    case keyfind(Target, 1, L) of
        {_,Pid} ->
            request_target:connect(Pid, Req),
            {noreply, L};
        false ->
            case request_target:start_link(Req, Target) of
                {ok,Pid} ->
                    {noreply, [{Target,Pid}|L]};
                ignore ->
                    {noreply, L};
                {error,Reason} ->
                    {stop,Reason}
            end
    end;

handle_cast({cancel,Req}, L) ->
    lists:foreach(fun ({_Target,Pid}) ->
                          request_target:cancel(Pid, Req)
                  end, L),
    {noreply,L};

handle_cast(_, State) ->
    {noreply,State}.

handle_call(pending_requests, _From, L1) ->
    L2 = [{Target, request_target:pending(Pid)}
          || {Target,Pid} <- L1],
    Fun = fun ({_,[]}) -> false; (_) -> true end,
    Reqs = lists:sort(lists:filter(Fun, L2)),
    {reply,Reqs,L1};

handle_call(targets, _From, L) ->
    {reply,L,L}.

handle_info({'EXIT',Pid,_Reason}, L) ->
    {noreply, lists:keydelete(Pid, 2, L)};

handle_info(_, L) ->
    {noreply,L}.
