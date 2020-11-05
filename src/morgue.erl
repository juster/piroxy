%%% Somewhere to temporarily store all the bodies!
%%%

-module(morgue).
-behavior(gen_server).
-include("../include/phttp.hrl").
-import(lists, [foreach/2]).
-export([start/0, start_link/0, append/2, forward/2, mute/1, forget/1]).
-export([init/1, handle_call/3, handle_cast/2]).

%%%
%%% EXTERNAL FUNCTIONS
%%%

start() ->
    gen_server:start({local,?MODULE}, ?MODULE, [], []).

start_link() ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

append(Key, Body) ->
    gen_server:cast(?MODULE, {append,Key,Body}).

%%take(Key) ->
%%    gen_server:call(?MODULE, {take,Key}).

forward(Key, Pid) ->
    gen_server:call(?MODULE, {forward,Key,Pid}).

mute(Key) ->
    gen_server:cast(?MODULE, {mute,Key}).

forget(Key) ->
    gen_server:cast(?MODULE, {forget,Key}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    {ok,{ets:new(?MODULE, [duplicate_bag,private]), dict:new()}}.

handle_cast({append,Key,Body}, {Tab,D}) ->
    case Body of
        eof ->
            ?DBG("append", [{key,Key},{body,Body}]);
        _ ->
            ok
    end,
    ets:insert(Tab, {Key,Body}),
    case dict:find(Key, D) of
        {ok,Pid} ->
            pipipe:drip(Pid, Key, Body);
        error ->
            ok
    end,
    {noreply, {Tab,D}};

handle_cast({forget,Key}, {Tab,D}) ->
    %% XXX: does no sanity checks
    ets:delete(Tab, Key),
    {noreply, {Tab, dict:erase(Key, D)}};

handle_cast({mute,Key}, {Tab,D}) ->
    {noreply,{Tab, dict:erase(Key, D)}}.

handle_call({forward,Key,Pid}, _From, {Tab,D0}) ->
    %%?DBG("forward", {key,Key,pid,Pid}),
    case dict:find(Key, D0) of
        {ok,_} ->
            {reply, {error,already_taken}, {Tab,D0}};
        error ->
            D = dict:store(Key, Pid, D0),
            foreach(fun ({_,Body}) ->
                            pipipe:drip(Pid, Key, Body)
                    end, ets:lookup(Tab, Key)),
            {reply, ok, {Tab,D}}
    end.
