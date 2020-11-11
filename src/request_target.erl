-module(request_target).
-behavior(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").
-import(lists, [foreach/2, reverse/1, keytake/3, keydelete/3, partition/2]).

-record(stats, {nproc=0,nmax=0,nfail=0,nsuccess=0}).
-record(state, {todo=[], sent=[], waitlist=[], stats, hostinfo}).

%% Awful.
-define(DEC(Field, S), S#state{stats=S#state.stats#stats{Field=(S#state.stats)#stats.Field-1}}).
-define(INC(Field, S), S#state{stats=S#state.stats#stats{Field=(S#state.stats)#stats.Field+1}}).

-export([start_link/2, connect/2, cancel/2, notify/2, pending/1, retire_self/1]).
-export([init/1, terminate/2,
         handle_call/3, handle_cast/2, handle_continue/2, handle_info/2]).

%%% called by request_handler

start_link(Req, HostInfo) ->
    gen_server:start_link(?MODULE, [Req, HostInfo], []).

connect(Pid, Id) ->
    gen_server:cast(Pid, {connect,Id}).

cancel(Pid, Id) ->
    gen_server:cast(Pid, {cancel,Id}).

%%% called by outbound

notify(Pid, A) ->
    gen_server:cast(Pid, {notify,A,self()}).

retire_self(Pid) ->
    gen_server:cast(Pid, {retire_self,self()}).

%%% called by whomever

pending(Pid) ->
    gen_server:call(Pid, pending).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([Req, HostInfo]) ->
    process_flag(trap_exit, true),
    {ok,Pid} = http_res_sock:start_link(HostInfo),
    ?TRACE(Req, element(2,HostInfo), ">>", io_lib:format("outbound started: ~p", [Pid])),
    {ok,
     #state{todo=[Req], waitlist=[Pid], stats=#stats{nproc=1,nmax=1}, hostinfo=HostInfo},
     {continue, check_lists}}.

terminate(Reason, #state{todo=Ltodo, sent=Lsent}) ->
    %% XXX: Child procs should be exited automatically after teminate.
    foreach(fun (Req) ->
                    piroxy_events:fail(Req, http, Reason)
            end, Ltodo),
    foreach(fun ({_Pid,Req}) ->
                    piroxy_events:fail(Req, http, Reason)
            end, Lsent),
    ok.

handle_call(pending, _From, S) ->
    {reply, [Req || {_,Req} <- S#state.sent], S};

handle_call(_, _, S) ->
    {reply, ok, S}.

%%%
%%% from request_manager
%%%

handle_cast({connect,Req}, S) ->
    Ltodo = S#state.todo ++ [Req],
    {noreply, S#state{todo=Ltodo}, {continue,check_lists}};

handle_cast({cancel,Id}, S0) ->
    Ltodo = lists:delete(Id, S0#state.todo),
    case lists:keytake(Id, 2, S0#state.sent) of
        false ->
            {noreply,
             S0#state{todo=Ltodo},
             {continue,check_lists}};
        {value,{Pid,_},Lsent} ->
            ?DBG("cancel", [{session,Id},{stopping,Pid}]),
            http_res_sock:stop(Pid),
            {noreply,
             ?DEC(nproc, S0#state{todo=Ltodo,sent=Lsent}),
             {continue,check_lists}}
    end;

%%%
%%% from outbound
%%%

handle_cast({notify,ready,OutPid}, S) ->
    case S#state.todo of
        [] ->
            %% If todo list is empty, then add Pid to waiting list.
            Waitlist = S#state.waitlist ++ [OutPid],
            {noreply,S#state{waitlist=Waitlist}};
        [Req|Ltodo] ->
            %% O/W pop off the todo list and push to sent list.
            case http_pipe:listen(Req, OutPid) of
                ok ->
                    Lsent = S#state.sent ++ [{OutPid,Req}],
                    {noreply,S#state{todo=Ltodo, sent=Lsent}};
                {error,unknown_session} ->
                    %% Sometimes the session is closed before we can get to it.
                    Waitlist = S#state.waitlist ++ [OutPid],
                    {noreply,
                     S#state{todo=Ltodo,waitlist=Waitlist},
                     {continue,check_lists}};
                {error,Reason} ->
                    {stop,Reason,S}
            end
    end;

%%% Called when the request is finished (i.e. the response is completed).
handle_cast({notify,done,Pid}, S0) ->
    Lsent = keydelete(Pid, 1, S0#state.sent),
    %%?DBG("finish_request", [{req,Req}]),
    {noreply,?INC(nsuccess,S0#state{sent=Lsent})};

handle_cast({notify,A,_}, S0) ->
    {stop,{unknown_notify,A}, S0};

%%% retire_self is called when an outbound pid upgrades their protocol.
handle_cast({retire_self,Pid}, S0) ->
    unlink(Pid),
    S1 = redo(Pid, S0),
    case {S1#state.todo, S1#state.sent} of
        {[], []} ->
            {stop,shutdown,S1};
        {_, []} ->
            outbound:start_link(S1#state.hostinfo),
            {noreply, S1};
        {[], _} ->
            {noreply, ?DEC(nproc, S1)}
    end.

handle_continue(check_lists, S) ->
    case {S#state.sent, S#state.todo, S#state.waitlist} of
        {[],[],_} ->
            %% Request todo list AND active request list is empty.
            {stop,shutdown,S};
        {_,[],_} ->
            %% Request todo list is empty.
            {noreply,S};
        {_,[Req|_],[]} ->
            N = S#state.stats,
            if
                N#stats.nproc < N#stats.nmax ->
                    %% spawn a new proc
                    {ok,Pid} = http_res_sock:start_link(S#state.hostinfo),
                    Host = element(2,S#state.hostinfo),
                    ?TRACE(Req, Host, ">", io_lib:format("outbound started: ~p", [Pid])),
                    {noreply, ?INC(nproc, S#state{waitlist=[Pid]}), {continue,check_lists}};
                true ->
                    {noreply,S}
            end;
        {_, [Req|Ltodo], [Pid|Waitlist]} ->
            case http_pipe:listen(Req, Pid) of
                ok ->
                    Lsent = S#state.sent ++ [{Pid,Req}],
                    {noreply, S#state{sent=Lsent, todo=Ltodo, waitlist=Waitlist}};
                {error,unknown_session} ->
                    %% Ignore dropped sessions.
                    {noreply, S#state{todo=Ltodo}, {continue,check_lists}};
                {error,Rsn} ->
                    {stop,Rsn,S}
            end
    end.

%% Unexpected errors in outbound process.
handle_info({'EXIT',Pid,Reason}, S0) ->
    ?TRACE(0, element(2,S0#state.hostinfo), ">>", io_lib:format("outbound closed: ~p", [Pid])),
    FailType = failure_type(Reason),
    S1 = case FailType of
             soft ->
                 %%L1 = S0#state.todo,
                 %%S_ = redo(Pid, S0),
                 %%L2 = lists:subtract(L1, S_#state.todo),
                 %%?DBG("handle_info", [{redoing, L2}]),
                 %%S_;
                 redo(Pid, S0);
             hard ->
                 S_ = redo(Pid, S0),
                 ?INC(nfail, S_);
             fatal ->
                 ?INC(nfail, S0)
         end,
    if
        FailType == fatal ->
            %% Does NOT try to redo the sent requests.
            {Lpid,Lsent} = partition(fun ({Pid_,_})
                                           when Pid == Pid_ ->
                                             true;
                                         (_) ->
                                             false
                                     end, S1#state.sent),
            foreach(fun ({_,Req}) ->
                            piroxy_events:fail(Req, http, Reason)
                    end, Lpid),
            Lwait = lists:delete(Pid, S1#state.waitlist),
            {noreply, S1#state{waitlist=Lwait,sent=Lsent}};
        S1#state.stats#stats.nfail > 5 ->
            %% We have reached the maximum failure count, so we must abort.
            {stop,Reason,S1};
        S1#state.todo /= [] ->
            %% Do not decrement the process count, since we start a replacement
            %% process.
            {ok,Pid2} = http_res_sock:start_link(S1#state.hostinfo),
            Lwait = S1#state.waitlist ++ [Pid2],
            {noreply, S1#state{waitlist=Lwait}, {continue,check_lists}};
        S1#state.sent /= [] ->
            %% No more requests to do, but there are pending requests sent to
            %% other processes.
            {noreply, ?DEC(nproc, S1)};
        true ->
            {stop,shutdown,S1}
    end;

handle_info(_, S) ->
    {noreply,S}.

failure_type(shutdown) -> soft;
failure_type({shutdown,{timeout,active}}) -> hard;
failure_type({ssl_error,_}) -> hard;
failure_type({tcp_error,_}) -> hard;
failure_type({shutdown,cancelled}) -> hard;
failure_type(_) -> fatal.

%%% Move requests that were sent to Pid back into todo list.
%%% Remove Pid from the waitlist (sanity check).
%%% Calls http_pipe:reset on all new todo list entries.
redo(Pid, S) ->
    Lwait = lists:delete(Pid, S#state.waitlist),
    {Lpid,Lsent} = lists:partition(fun ({Pid_,Req}) when Pid == Pid_ ->
                                           http_pipe:reset(Req),
                                           true;
                                       (_) ->
                                           false
                                   end, S#state.sent),
    Ltodo = [Req || {_,Req} <- Lpid] ++ S#state.todo,
    S#state{waitlist=Lwait, todo=Ltodo, sent=Lsent}.
