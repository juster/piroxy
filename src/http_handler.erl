-module(http_handler).
-export([start_link/0, sup/0]).
-export([init/1, handle_call/2, handle_event/2]).

start_link() ->
    Pid = spawn_link(?MODULE, sup, []),
    {ok,Pid}.

sup() ->
    gen_event:add_sup_handler(piroxy_events, ?MODULE, []),
    loop().

loop() ->
    receive
        {'gen_event_EXIT', _Pid, {swapped,_,_}} ->
            loop();
        {'gen_event_EXIT', _Pid, Reason} ->
            exit(Reason)
    end.

init([]) ->
    {ok, []}.

handle_call(_, S) ->
    {reply,ok,S}.

handle_event({connect, Id, Http, Target}, S)
  when Http == http; Http == https ->
    request_manager:connect(Id, http, Target),
    {ok,S};

handle_event({send, Id, http, Term}, S) ->
    http_pipe:send(Id, Term),
    {ok,S};

handle_event({recv, Id, http, Term}, S) ->
    http_pipe:recv(Id, Term),
    {ok,S};

handle_event({fail,Id,http,cancelled}, S) ->
    http_pipe:cancel(Id),
    request_manager:cancel(Id),
    {ok,S};

handle_event({fail,Id,http,Reason}, S) ->
    http_pipe:reset(Id),
    http_pipe:recv(Id, {error,Reason}),
    {ok,S}.
