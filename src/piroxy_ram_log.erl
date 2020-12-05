-module(piroxy_ram_log).
-behavior(gen_event).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-import(lists, [foreach/2]).
-record(state, {matchfun=nomatch, conntab, logtab, bodytab,
                accum=dict:new()}).

-export([start_link/0, watchman/0]).
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

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    {ok,#state{conntab=ets:new(connections, [private,bag]),
               logtab=ets:new(log, [private,duplicate_bag]),
               bodytab=ets:new(morgue, [private,set])}}.

handle_event(_, #state{matchfun=nomatch}=S) ->
    {ok, S};

handle_event(T, S) ->
    MatchFun = S#state.matchfun,
    case MatchFun(T) of
        true ->
            log_event(T, S);
        false ->
            {ok,S}
    end.

handle_call(_, S) ->
    {ok,ok,S}.

%%%
%%% HIDDEN
%%%

log_event({Id,connect,Time,Proto,Target}, S) ->
    ets:insert(S#state.conntab, {Id,Time,Proto,Target}),
    {ok,S};

log_event({Id,Dir,Time,http,Term}=T, S)
  when Dir =:= send; Dir =:= recv ->
    case Term of
        #head{bodylen=0} ->
            %% body will not be accumulated
            ets:insert(S#state.logtab, T),
            {ok, S};
        #head{}=Head ->
            ets:insert(S#state.logtab, T),
            M0 = S#state.accum,
            M = M0#{{Id,Dir} => {Head,[]}},
            {ok, S#state{accum=M}};
        {body,Body} ->
            {ok, accum_body(Id, Dir, Time, Body, S)};
        eof ->
            {ok, store_body(Id, Dir, S)}
    end;

log_event(T, S) ->
    ets:insert(S#state.logtab, T),
    S.

accum_body(Id, Dir, Time, Bin, S) ->
    K = {Id,Dir},
    M0 = #{K:={Head,L}} = S#state.accum, % XXX: error if not found
    M = M0#{K=>{Head,[{Time,Bin}|L]}},
    S#state{accum=M}.

store_body(Id, Dir, S) ->
    case S#state.accum of
        #{{Id,Dir} := {_Head,L0}} ->
            L = lists:reverse(L0),
            Body = iolist_to_binary([X || {_,X} <- L]),
            Digest = crypto:hash(sha512, Body),
            LogTab = S#state.logtab,
            BodyTab = S#state.bodytab,
            Fun = fun ({Time,Bin}) ->
                          %% XXX: do {body,...} messages always use binary?
                          T = {Id,Time,Dir,http,{body,Digest,byte_size(Bin)}},
                          ets:insert(LogTab, T)
                  end,
            foreach(Fun, Body),
            ets:insert(BodyTab, {Digest,Body}),
            S#state{accum=maps:remove({Id,Dir}, S#state.accum)};
        _ ->
            ?LOG_ERROR("could not finalize body for unknown Id: ~p", [Id]),
            %% XXX: delete other records for Id?
            S
    end.
