-module(piwatch).
-behavior(gen_event).
-include_lib("kernel/include/logger.hrl").
-include("../include/pihttp_lib.hrl").

-export([start/0, stop/0, hostname/1, watch/2, watch/3, forget/1,
         which_triggers/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2]).

%%% EXPORTS

start() ->
    gen_event:add_handler(pievents, ?MODULE, []).

stop() ->
    gen_event:delete_handler(pievents, ?MODULE, []).

hostname(Name) when is_binary(Name) ->
    {'_',Name,'_'};

hostname(Name) when is_list(Name) ->
    {'_',list_to_binary(Name),'_'}.

watch(Name, TargetProg) ->
    watch(Name, TargetProg, '_').

watch(Name, TargetProg, HeadProg) ->
    gen_event:call(pievents, ?MODULE, {watch,Name,TargetProg,HeadProg}).

forget(Name) ->
    gen_event:call(pievents, ?MODULE, {forget,Name}).

which_triggers() ->
    gen_event:call(pievents, ?MODULE, which_triggers).

%%% BEHAVIOR CALLBACKS

init([]) ->
    {ok,{null,[],dict:new()}}.

handle_event(_, {null,_,_}=State) ->
    {ok,State};

handle_event({make_request,Req,HostInfo,Head}, {Spec,L,D0} = State) ->
    case ets:match_spec_run([{HostInfo,Head}], Spec) of
        [] ->
            {ok,State};
        [true] ->
            D = dict:store(Req, Head, D0),
            {ok,_} = timer:send_after(?REQUEST_TIMEOUT, {check,Req}),
            {ok,{Spec,L,D}}
    end;

handle_event({cancel_request,Req}, {Spec,L,D0}) ->
    {Head,D} = dict:take(Req,D0),
    log(cancel, Req, format_head(Head)),
    {ok, {Spec,L,D}};

handle_event({fail_request,Req}, {Spec,L,D0}) ->
    {Head,D} = dict:take(Req,D0),
    log(fail, Req, format_head(Head)),
    {ok, {Spec,L,D}};

handle_event({make_tunnel,Req,_}, {Spec,L,D0}) ->
    D = dict:erase(Req,D0),
    {ok, {Spec,L,D}};

handle_event({respond,Req,#head{}=Res}, {Spec,L,D0}) ->
    case dict:take(Req,D0) of
        {Req_,D} ->
            log(response, Req, {Req_#head.line,Res#head.line}),
            {ok, {Spec,L,D}};
        error ->
            {ok, {Spec,L,D0}}
    end;

handle_event(_, State) ->
    {ok,State}.

handle_call({watch,Name,TargetProg,HeadProg}, {_,L,S} = State) ->
    MatchProg = {{TargetProg,HeadProg},[],[true]},
    MatchSpec = [MatchProg|[V || {_,V} <- L]],
    try ets:match_spec_compile(MatchSpec) of
        C -> {ok, ok, {C,[{Name,MatchProg}|L],S}}
    catch
        error:badarg:_Stack ->
            {ok, {error,badarg}, State}
%%            io:format("*DING*~n"),
%%            Rsn = case test(MatchProg) of
%%                      {error,Rsn_} -> Rsn_;
%%                      ok -> exit({badarg,Stack}) % should never happen!
%%                  end,
%%            {ok, {error,Rsn}, State}
    end;

handle_call({forget,Name}, {_,L0,S}) ->
    case lists:keydelete(Name, 1, L0) of
        [] ->
            {ok,ok,{null,[],S}};
        L ->
            MatchSpec = ets:match_spec_compile([V || {_,V} <- L]),
            {ok,ok,{MatchSpec,L,S}}
    end;

handle_call(which_triggers, {_,L,_} = State) ->
    {ok, [K || {K,_} <- L], State};

handle_call(_, State) ->
    {ok,ok,State}.

handle_info({check,Req}, {_,_,D} = State) ->
    case dict:find(Req,D) of
        {ok,Head} ->
            ?LOG_INFO("PIWATCH: Long-running request ~p~n~p",
                      [Req,format_head(Head)]);
        error ->
            ok
    end,
    {ok,State};

handle_info(_, State) ->
    {ok,State}.

log(Flag, Req, Term) ->
    ?LOG_INFO("PIWATCH [~p] ~p~n~p", [Flag,Req,Term]).

format_head(H) ->
    {H#head.line, fieldlist:to_proplist(H#head.headers)}.
