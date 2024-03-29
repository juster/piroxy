-module(request_manager).
-behavior(gen_server).

-import(lists, [foreach/2, keyfind/3, keytake/3]).
-include_lib("kernel/include/logger.hrl").
-include("../include/pihttp_lib.hrl").

-export([nextid/0, connect/2, cancel/1, pending/0, targets/0]). % calls
-export([init/1, handle_cast/2, handle_call/3, handle_info/2]).

%%%
%%% EXPORTS
%%%

nextid() ->
    gen_server:call(?MODULE, nextid).

connect(Req, Target) ->
    gen_server:cast(?MODULE, {connect,Req,Target}).

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
    {ok, {1,[]}}.

handle_cast({connect,Req,{Proto,Host,Port} = Target}, {I,L}=S) ->
    Secure = case Proto of
                 http -> false;
                 https -> true;
                 _ -> exit(badarg)
             end,
    HttpTarget = {Host,Port,Secure},
    case keyfind(Target, 1, L) of
        {_,Pid} ->
            piroxy_events:connect(Req, http, HttpTarget),
            request_target:connect(Pid, Req),
            {noreply, S};
        false ->
            case request_target:start_link(HttpTarget) of
                {ok,Pid} ->
                    piroxy_events:connect(Req, http, HttpTarget),
                    request_target:connect(Pid, Req),
                    {noreply, {I,[{Target,Pid}|L]}};
                ignore ->
                    {noreply, S};
                {error,Reason} ->
                    {stop,Reason,S}
            end
    end;

%%% XXX: very inefficient, we do not know which target handles this request
handle_cast({cancel,Req}, {_,L}=S) ->
    lists:foreach(fun ({_Target,Pid}) ->
                          request_target:cancel(Pid, Req)
                  end, L),
    {noreply,S}.

handle_call(nextid, _From, {I,L}) ->
    {reply, I, {I+1,L}};

handle_call(pending_requests, _From, {_,L1}=S) ->
    L2 = [{Target, request_target:pending(Pid)}
          || {Target,Pid} <- L1],
    Fun = fun ({_,[]}) -> false; (_) -> true end,
    Reqs = lists:sort(lists:filter(Fun, L2)),
    {reply,Reqs,S};

handle_call(targets, _From, {_,L}=S) ->
    {reply,L,S}.

handle_info({'EXIT',Pid,_Reason}, {I,L}) ->
    {noreply, {I, lists:keydelete(Pid, 2, L)}}.
