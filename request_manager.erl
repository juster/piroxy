-module(request_manager).
-behavior(gen_server).

-include_lib("kernel/include/logger.hrl").

-define(OUTGOING_ERR_MAX, 3).

-record(rmstate, {hosttab, reqtab, pidtab}).

-record(hostconn, {hostinfo, pid, nfail=0}).

-export([start_link/0, new_request/2, next_request/0, close_request/1]).

%%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%%% exported interface functions

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], [{debug,[trace]}]).

%%% called by the inbound process

%% Request = {Method, Uri, Headers}
new_request(HostInfo, Request) ->
    gen_server:call(?MODULE, {new_request, HostInfo, Request}).

%%% called by the outbound process

next_request() ->
    gen_server:call(?MODULE, {next_request}).

close_request(Ref) ->
    gen_server:cast(?MODULE, {close_request, self(), Ref}).

%%% gen_server callbacks
%%%

init([]) ->
    case application:ensure_all_started(ssl) of
        {ok, _} ->
            process_flag(trap_exit, true),
            HostTab = ets:new(hosts, [set,private,{keypos,#hostconn.hostinfo}]),
            ReqTab = ets:new(requests, [bag,private]),
            PidTab = ets:new(pids, [set,private]),
            {ok, #rmstate{hosttab=HostTab, reqtab=ReqTab, pidtab=PidTab}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({new_request, HostInfo, Request}, {InPid, _Tag}, State) ->
    case open_connection(HostInfo, State) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        {ok, OutPid} ->
            Ref = erlang:make_ref(),
            ets:insert(State#rmstate.reqtab, {OutPid, InPid, Ref, Request}),
            outbound:new_request(OutPid),
            {reply, Ref, State}
    end;

handle_call({next_request}, {OutPid,_Tag}, State) ->
    case ets:match(State#rmstate.reqtab, {OutPid, '$1', '$2', '$3'}, 1) of
        '$end_of_table' ->
            {reply, null, State};
        {[], _Cont} ->
            {reply, null, State};
        {[[InPid, Ref, Request]], _Cont} ->
            {reply, {InPid, Ref, Request}, State}
    end.

handle_cast({close_request, OutPid, Ref}, State) ->
    case ets:match(State#rmstate.reqtab, {OutPid, '$1', Ref, '_'}, 1) of
        '$end_of_table' ->
            {stop, {unknown_request, Ref}, State};
        {[], _} ->
            {stop, {unknown_request, Ref}, State};
        {[[InPid]], _} ->
            inbound:close(InPid, Ref),
            ets:match_delete(State#rmstate.reqtab, {OutPid, InPid, Ref, '_'}),
            {noreply, State}
    end.

handle_info({'EXIT', Pid, Reason}, State) ->
    %% A normal exit can happen if the connection automatically closes when
    %% finished.
    case cleanup_pid(Pid, State) of
        {error, Reason} ->
            {stop, Reason, State};
        {ok, HostInfo} ->
            %% Reset the failure counter or increment it.
            case Reason of
                normal ->
                    ets:update_element(State#rmstate.hosttab, HostInfo, {#hostconn.nfail, 0});
                _ ->
                    ets:update_counter(State#rmstate.hosttab, HostInfo, {#hostconn.nfail, 1})
            end,
            %% Spawn a new outgoing process if there are more requests.
            case has_requests(Pid, State) of
                true ->
                    case open_connection(HostInfo, State) of
                        {error, Reason} ->
                            abort_requests(Pid, State, Reason);
                        {ok, NewPid} ->
                            ets:update_element(State#rmstate.reqtab, Pid, {1, NewPid})
                    end;
                false ->
                    ok
            end,
            {noreply, State}
    end.

%%%
%%% internal utility functions
%%%

%% Use a pre-existing connection to connect to the host if it already exists.
%% If not, create a new outgoing process.
%%
open_connection(HostInfo, #rmstate{hosttab=HostTab,pidtab=PidTab}) ->
    case ets:lookup(HostTab, HostInfo) of
        [#hostconn{pid=OutPid}] when OutPid =/= null ->
            {ok, OutPid};
        [#hostconn{pid=null,nfail=Nfail}] when Nfail > ?OUTGOING_ERR_MAX ->
            {error, {max_connection_fail, Nfail}};
        _ ->
            %% No matching record or pid is null.
            {ok, OutPid} = connect(HostInfo),
            %% Overwrite any existing hostconn record for that host.
            ets:insert(HostTab, #hostconn{hostinfo=HostInfo, pid=OutPid}),
            ets:insert(PidTab, {OutPid, HostInfo}),
            {ok, OutPid}
    end.

connect({http,Host,Port}) ->
    outbound:connect_http(Host, Port);

connect({https,Host,Port}) ->
    outbound:connect_https(Host, Port);

connect(_) ->
    {error, badarg}.

cleanup_pid(OutPid, #rmstate{pidtab=PidTab,hosttab=HostTab}) ->
    case ets:lookup(PidTab, OutPid) of
        [] ->
            {error, {unknown_pid, OutPid}};
        [{_, HostInfo}] ->
            ets:delete(PidTab, OutPid),
            ets:update_element(HostTab, HostInfo, {#hostconn.pid, null}),
            {ok, HostInfo}
    end.

has_requests(OutPid, State) ->
    case ets:match(State#rmstate.reqtab, OutPid, 1) of
        '$end_of_table' ->
            false;
        [] ->
            false;
        [_] ->
            true
    end.

abort_requests(OutPid, State, Reason) ->
    L = ets:lookup(State#rmstate.reqtab, OutPid),
    lists:foreach(fun ({_, InPid, Ref}) ->
                          inbound:abort_request(InPid, Ref, Reason)
                  end, L),
    ets:delete(State#rmstate.reqtab, OutPid).
