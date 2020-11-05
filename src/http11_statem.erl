-module(http11_statem).
-behavior(gen_statem).
-include("../include/phttp.hrl").

-export([start_link/2, read/2, activate/1, shutdown/2, expect_bodylen/2]).
-export([init/1, callback_mode/0, handle_event/4]).

%%%
%%% EXTERNAL INTERFACE
%%%

%% Arguments:
%% 1. Timeouts: {active timeout, idle timeout}
%% 2. gen_statem options
start_link({_,_}=Timeouts, Opts) ->
    gen_statem:start_link(?MODULE, [self(),Timeouts], Opts).

read(Pid, Bin) ->
    gen_statem:cast(Pid, {data,Bin}).

activate(Pid) ->
    gen_statem:cast(Pid, start_active_timer).

shutdown(Pid, Reason) ->
    gen_statem:cast(Pid, {shutdown,Reason}).

expect_bodylen(Pid, Len) ->
    gen_statem:cast(Pid, {expect_bodylen, Len}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

callback_mode() -> [handle_event_function, state_enter].

init([Pid,Ts]) ->
    {ok, eof, {null,Pid,Ts}}.

%% use enter events to choose between the idle timeout and active timeout
handle_event(enter, _, eof, {_,_,{_,T2}}) ->
    {keep_state_and_data,
     [{{timeout,idle},T2,[]},
      {{timeout,active},cancel}]};

handle_event(enter, _, _, {_,_,{T1,_}}) ->
    {keep_state_and_data,
     [{{timeout,idle},cancel},
      {{timeout,active},T1,[]}]};

%% switch to the active timeout when http11_res sends data and expects a result
handle_event(cast, start_active_timer, _, {_,_,{T1,_}}) ->
    {keep_state_and_data,
     [{{timeout,idle},cancel},
      {{timeout,active},T1,[]}]};

handle_event({timeout,idle}, _, _, _) ->
    %% use the idle timeout to automatically close
    {stop, {shutdown,closed}};

handle_event({timeout,active}, _, _, _) ->
    {stop, {shutdown,timeout}};

handle_event(cast, {data,<<>>}, _, _) ->
    keep_state_and_data;

handle_event(cast, {data,empty}, _, _) ->
    keep_state_and_data;

handle_event(cast, {data,_}, eof, {_,Pid,Ts}) ->
    {next_state, head,
     {pimsg:head_reader(),Pid,Ts},
     postpone};

handle_event(cast, {data,Bin}, head, {Reader0,Pid,Ts}) ->
    case pimsg:head_reader(Reader0, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            {keep_state,{Reader,Pid,Ts}};
        {done,StatusLine,Headers,Rest} ->
            Pid ! {http,{head,StatusLine,Headers}},
            {next_state,bodywait, {null,Pid,Ts},
             {next_event,cast,{data,Rest}}}
    end;

handle_event(cast, {expect_bodylen,0}, bodywait, {_,Pid,Ts}) ->
    Pid ! {http,eof},
    {next_state,eof, {null,Pid,Ts}};

handle_event(cast, {expect_bodylen,Len}, bodywait, {_,Pid,Ts}) ->
    {next_state,body, {pimsg:body_reader(Len),Pid,Ts}};

%% postpone any message other than expect_bodylen
handle_event(cast, _, bodywait, _) ->
    {keep_state_and_data, postpone};

%% used to stop the process, without bypassing the messages in the queue
handle_event(cast, {shutdown,Reason}, eof, _) ->
    ?DBG("shutdown", [{reason,Reason}]),
    {stop, {shutdown,Reason}};

handle_event(cast, {data,Bin1}, body, {Reader0,Pid,Ts}) ->
    case pimsg:body_reader(Reader0, Bin1) of
        {error,Reason} ->
            {stop, Reason};
        {continue,empty,Reader} ->
            {keep_state,{Reader,Pid,Ts}};
        {continue,Bin2,Reader} ->
            Pid ! {http,{body,Bin2}},
            {keep_state,{Reader,Pid,Ts}};
        {done,Bin2,Rest} ->
            case Bin2 of
                empty -> ok;
                <<>> -> ok;
                _ -> Pid ! {http,{body,Bin2}}
            end,
            Pid ! {http,eof},
            {next_state,eof,
             {null,Pid,Ts},
             {next_event,cast,{data,Rest}}}
    end.
