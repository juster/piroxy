-module(piwatch).
-behavior(gen_event).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-export([start/0, stop/0, hostname/1, watch/4, forget/1]).
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

watch(Name, TargetProg, HeadProg, Result) ->
    gen_event:call(pievents, ?MODULE, {watch,Name,TargetProg,HeadProg,Result}).

forget(Name) ->
    gen_event:call(pievents, ?MODULE, {forget,Name}).

%%% BEHAVIOR CALLBACKS

init([]) ->
    {ok,{null,[],sets:new()}}.

handle_event(_, {null,_}=State) ->
    {ok,State};

handle_event({make_request,Req,HostInfo,Head}, {Spec,L,S0} = State) ->
    case ets:match_spec_run([{HostInfo,Head}], Spec) of
        [] ->
            {ok,State};
        [Result] ->
            log(request, Req, Result),
            S = sets:add_element(Req,S0),
            {ok,{Spec,L,S}}
    end;

handle_event({fail_request,Req,Reason}, {_,_,S} = State) ->
    case sets:is_element(Req,S) of
        true ->
            log(fail, Req, Reason);
        false ->
            ok
    end,
    {ok,State};

handle_event({respond,Req,#head{}=Head}, {_,_,S} = State) ->
    case sets:is_element(Req,S) of
        true ->
            log(response_head, Req, Head);
        false ->
            ok
    end,
    {ok,State};

handle_event({close_response,Req}, {Spec,L,S0}) ->
    {ok, {Spec, L, sets:del_element(Req, S0)}};

handle_event(_, State) ->
    {ok,State}.

handle_call({watch,Name,TargetProg,HeadProg,Result}, {_,L,S} = State) ->
    MatchProg = {{TargetProg,HeadProg},[],[Result]},
    MatchSpec = [MatchProg|[V || {_,V} <- L]],
    try ets:match_spec_compile(MatchSpec) of
        C -> {ok, ok, {C,[{Name,MatchProg}|L],S}}
    catch
        error:badarg:Stack ->
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

handle_call(_, State) ->
    {ok,State}.

handle_info(_, State) ->
    {ok,State}.

log(Flag, Req, Term) ->
    ?LOG_INFO("PIWATCH [~p] ~p~n~p", [Flag,Req,Term]).

test(MatchProg) ->
    case ets:test_ms({null,null}, [MatchProg]) of
        {ok,_} ->
            ok;
        {error,_} = Err ->
            Err
    end.
