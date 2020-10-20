%%% Somewhere to temporarily store all the bodies!
%%%

-module(morgue).
-behavior(gen_server).
-include("../include/phttp.hrl").
-import(lists, [foreach/2]).
-export([start/0, start_link/0, append/2, listen/1, forget_request/1]).
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

listen(Key) ->
    gen_server:cast(?MODULE, {listen,Key,self()}).

forget_request(Key) ->
    gen_server:cast(?MODULE, {forget_request,Key}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([]) ->
    {ok,{ets:new(?MODULE, [duplicate_bag,private]), dict:new()}}.

handle_cast({append,Key,Body}, {Tab,D}) ->
    case dict:find(Key, D) of
        {ok,Pid} ->
            %%?DBG("append", {sent,Pid,{body,Key,Body}}),
            Pid ! {body,Key,Body};
        error ->
            %%?DBG("append", {insert,Key,Body}),
            ets:insert(Tab, {Key,Body})
    end,
    {noreply, {Tab,D}};

handle_cast({listen,Key,Pid}, {Tab,D0}) ->
    %% does not check if someone is already listening...
    %%?DBG("listen", {key,Key,pid,Pid}),
    D = dict:store(Key, Pid, D0),
    foreach(fun (Body) ->
                    %%?DBG("listen", {sent,Pid,{body,Key,Body}}),
                    Pid ! {body,Key,Body}
            end, take(Key, Tab)),
    {noreply, {Tab,D}};

handle_cast({forget_request,Key}, {Tab,D}) ->
    %% XXX: does no sanity checks
    {noreply, {Tab, dict:erase(Key, D)}}.

handle_call(_, _, State) ->
    {reply, ok, State}.

%%%
%%% INTERNAL FUNCTIONS
%%%

take(Key, Tab) ->
    L = [X || {_,X} <- ets:lookup(Tab, Key)], % may be empty!
    true = ets:delete(Tab, Key),
    L.
