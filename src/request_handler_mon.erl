-module(request_handler_mon).

-export([start_link/0]).

start_link() ->
    {ok,spawn_link(fun start/0)}.

start() ->
    ok = gen_event:add_sup_handler(pievents, request_handler, []),
    loop().

loop() ->
    receive
        shutdown ->
            gen_event:delete_handler(pievents, request_handler, []),
            exit(shutdown);
        {gen_event_EXIT,_,normal} ->
            loop();
        {gen_event_EXIT,_,{swapped,_,_}} ->
            loop();
        {gen_event_EXIT,_,shutdown} ->
            %% The gen_event process terminated before us!
            exit(shutdown);
        {gen_event_EXIT,_,Reason} ->
            exit(Reason)
    end.
