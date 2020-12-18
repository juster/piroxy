-module(piroxy_ram_log).
-behavior(gen_event).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-import(lists, [foreach/2, map/2, zip/2, unzip/1, reverse/1]).
-record(state, {matchfun=nomatch, conntab, logtab, bodytab,
                accum=dict:new()}).

-export([start_link/0, watchman/0]).
-export([filter/1, connections/0, log/1, body/1]).
-export([init/1, handle_event/2, handle_call/2]).

%%%
%%% EXPORTS
%%%

start_link() ->
    {ok, spawn_link(?MODULE,watchman,[])}.

watchman() ->
    case gen_event:add_sup_handler(piroxy_events, ?MODULE, []) of
        ok ->
            receive
                {gen_event_EXIT,_,shutdown} ->
                    %% the whole app is presumably shutting down
                    ok;
                {gen_event_EXIT,_,Rsn} ->
                    exit(Rsn)
            end
    end.

filter(Term) ->
    gen_event:call(piroxy_events, ?MODULE, {filter,Term}).

connections() ->
    gen_event:call(piroxy_events, ?MODULE, connections).

log(ConnId) ->
    gen_event:call(piroxy_events, ?MODULE, {log,ConnId}).

body(Digest) ->
    gen_event:call(piroxy_events, ?MODULE, {body,Digest}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    {ok,#state{conntab=ets:new(connections, [private,bag]),
               logtab=ets:new(log, [private,duplicate_bag]),
               bodytab=ets:new(morgue, [private,set])}}.

handle_event(_, #state{matchfun=nomatch}=S) ->
    {ok, S};

handle_event(T, #state{matchfun=matchall}=S) ->
    log_event(T, S);

handle_event(T, S) ->
    MatchFun = S#state.matchfun,
    case MatchFun(T) of
        true ->
            log_event(T, S);
        false ->
            {ok,S}
    end.

handle_call({filter,A}, S) when is_atom(A) ->
    if
        A == matchall; A == nomatch ->
            {ok, ok, S#state{matchfun=A}};
        true ->
            {ok, {error,badarg}, S}
    end;

handle_call(connections, S) ->
    {ok, ets:tab2list(S#state.conntab), S};

handle_call({log,ConnId}, S) ->
    {ok, ets:lookup(S#state.logtab, ConnId), S};

handle_call({body,Digest}, S) ->
    Body = case ets:lookup(S#state.bodytab, Digest) of
               [] ->
                   not_found;
               [Bin] ->
                   Bin
           end,
    {ok,Body,S}.

%%%
%%% HIDDEN
%%%

log_event({Id,connect,Time,Proto,Target}, S) ->
    ets:insert(S#state.conntab, {Id,Time,Proto,Target}),
    {ok,S};

log_event({Id,Dir,Time,http,Term}=T, S)
  when Dir =:= send; Dir =:= recv ->
    ets:insert(S#state.logtab, T),
    case Term of
        #head{bodylen=0} ->
            %% body will not be accumulated
            %%io:format("*DBG* [~B:~s] empty body no accum~n", [Id,Dir]),
            {ok, S};
        #head{} ->
            %%io:format("*DBG* [~B:~s] non-empty body~n", [Id,Dir]),
            D = dict:store({Id,Dir}, [], S#state.accum),
            {ok, S#state{accum=D}};
        {body,Body} ->
            {ok, accum_body(Id, Dir, Time, Body, S)};
        {fail,Reason}
          when Reason == cancelled; Reason == reset ->
            {ok, store_body(Id, Dir, S)};
        {error,_} ->
            {ok, store_body(Id, Dir, S)};
        eof ->
            {ok, store_body(Id, Dir, S)};
        {status,_} ->
            {ok, S}
    end;

log_event(T, S) ->
    ets:insert(S#state.logtab, T),
    {ok,S}.

accum_body(Id, Dir, Time, Bin, S) ->
    io:format("*DBG* accum_body!~n"),
    D0 = S#state.accum, % XXX: error if not found
    D = dict:append({Id,Dir}, {Time,Bin}, D0),
    S#state{accum=D}.

%% TODO: strip the chunked lines out of the body so that the same content
%% does not get a different digest if it is chunked at different bytes
store_body(Id, Dir, S) ->
    case dict:find({Id,Dir}, S#state.accum) of
        {ok,L1} ->
            {Stamps,Chunks} = unzip(L1),
            Digest = crypto:hash(sha512, Chunks),
            LogTab = S#state.logtab,
            BodyTab = S#state.bodytab,
            L2 = zip(Stamps, map(fun erlang:iolist_size/1, Chunks)),
            foreach(fun({Tstamp,Size}) ->
                            T = {Id,Tstamp,Dir,http,{body,Digest,Size}},
                            %%io:format("*DBG* [~p] store_body: ~p~n", [Id,T]),
                            ets:insert(LogTab, T)
                    end, L2),
            ets:insert(BodyTab, {Digest,Chunks}),
            S#state{accum=dict:erase({Id,Dir}, S#state.accum)};
        error ->
            %% there were no body messages
            io:format("*DBG* no body found for request ~p~n", [Id]),
            S
    end.
