-module(http_pipe).
-behavior(gen_server).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, start_shell/0, new/0, dump/0, sessions/0,
         send/2, listen/2, recv/2, reset/1, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%%% EXPORTS

start_link() ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

start_shell() ->
    case start_link() of
        {ok,Pid} ->
            unlink(Pid);
        {error,_} = Err ->
            Err
    end.

new() ->
    gen_server:call(?MODULE, new).

sessions() ->
    gen_server:call(?MODULE, sessions).

dump() ->
    gen_server:call(?MODULE, dump).

send(Id, Term) ->
    gen_server:cast(?MODULE, {send,Id,Term}).

listen(Id, Pid) ->
    gen_server:call(?MODULE, {listen,Id,Pid}).

reset(Id) ->
    gen_server:call(?MODULE, {reset,Id}).

cancel(Id) ->
    gen_server:cast(?MODULE, {cancel,Id}).

recv(Id, Term) ->
    gen_server:cast(?MODULE, {recv,Id,Term}).

%%% BEHAVIOR CALLBACKS

init([]) ->
    process_flag(trap_exit, true),
    MsgTab = ets:new(?MODULE, [duplicate_bag,private]),
    {ok, {MsgTab, [], 1}}.

handle_call(new, {Pid,_Ref}, {MsgTab,Sessions0,I}) ->
    %%link(Pid),
    Sessions = Sessions0 ++ [{I,Pid,null}],
    {reply, I, {MsgTab, Sessions, I+1}};

handle_call(sessions, _From, {_,Sessions,_}=State) ->
    {reply, Sessions, State};

handle_call(dump, _From, {MsgTab,_,_}=State) ->
    {reply, ets:tab2list(MsgTab), State};

%% The receive end of the pipe starts to 'listen' for send messages.
handle_call({listen,Id,Pid2}, _From, {MsgTab,Sessions0,I}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            {reply,{error,unknown_session},State};
        {_,Pid1,null} ->
            case lists:keyfind(Pid2, 3, Sessions0) of
                false ->
                    %% Ensure this is the first session for Pid2 and then send
                    %% any previously cached messages.
                    Msgs = [Msg || {_,Msg} <- ets:lookup(MsgTab, {Id,send})],
                    case sendall(Id, Pid2, Msgs) of
                        true ->
                            %% We do not have to "close" the send end of the
                            %% pipe because we never fully "opened" the
                            %% endpoint. To open the endpoint is to assign Pid2
                            %% to the keylist tuple entry.
                            %%
                            %% We do not flush because this is the only pending
                            %% pipeline for Pid2, it only now began listening.
                            {reply,ok,State};
                        false ->
                            %% Open the send end of the pipe by assigning a
                            %% receiving Pid2 in the keylist entry.
                            Sessions = lists:keyreplace(Id, 1, Sessions0,
                                                        {Id,Pid1,Pid2}),
                            {reply,ok,{MsgTab,Sessions,I}}
                    end;
                _ ->
                    %% This is not the first session for Pid2 and so we wait
                    %% until it has finished the previous one.
                    {reply,ok,State}
            end;
        {Id,_,Pid2} ->
            {reply,{error,{already_receiving,Id,Pid2}},State}
    end;

%% reset the recv side of the pipe involves forgetting the receiving pid and
%% preparing for it to be replaced by a new one
handle_call({reset,Id}, _From, {MsgTab,Sessions0,I}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            %% Do not be strict on recv endpoints about whether a sessions
            %% disappears.
            {reply,cancel,State};
        {_,Pid1,_Pid2} = T ->
            Received = case lists:keyfind(Pid1, 2, Sessions0) of
                           T ->
                               %% This is the active session for Pid1
                               case ets:match(MsgTab, {{recv,Id},'_'}, 1) of
                                   '$end_of_table' -> false;
                                   {[],_} -> false;
                                   _ -> true
                               end;
                           _ ->
                               false
                       end,
            case Received of
                true ->
                    %% Pid1 has received some data from Pid2! We must break the pipeline.
                    %% This will trigger 'cancel' events for every request from Pid1.
                    ?DBG("reset", [{shutdown,Pid1}]),
                    exit(Pid1, shutdown),
                    Sessions = cleanup(Id, MsgTab, Sessions0),
                    {reply,cancel,{MsgTab,Sessions,I}};
                false ->
                    %% Pid1 has not received data from Pid2, so we should be okay...
                    ets:delete(MsgTab, {recv,Id}),
                    Sessions = lists:keyreplace(Id, 1, Sessions0, {Id,Pid1,null}),
                    {reply,ok,{MsgTab,Sessions,I}}
            end
    end.

handle_cast({send, Id, Term}, {MsgTab,Sessions0,I}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            %% http_req_sock should not send to sessions that no longer exist.
            {stop,unknown_session,State};
        {_,_,null} ->
            ets:insert(MsgTab, {{Id,send}, Term}),
            {noreply,State};
        {_,Pid1,Pid2} = T ->
            ets:insert(MsgTab, {{Id,send}, Term}),
            case lists:keyfind(Pid2, 3, Sessions0) of
                T ->
                    %% If this is the first session in Pid2's pipeline then we do
                    %% not have to wait before we send it!
                    Pid2 ! {http_pipe,Id,Term},
                    case endterm(Term) of
                        true ->
                            %% We also close the send end of the pipe when an
                            %% 'eof' is received.
                            Sessions = close_send(Id, MsgTab, Sessions0),
                            {noreply, {MsgTab,Sessions,I}};
                        false ->
                            {noreply,{MsgTab,Sessions0,I}}
                    end;
                _ ->
                    {noreply,State}
            end
    end;

handle_cast({cancel,Id}, {MsgTab,Sessions0,I}) ->
    Sessions = cleanup(Id, MsgTab, Sessions0),
    {noreply, {MsgTab,Sessions,I}};

handle_cast({recv,Id,Term}, {MsgTab,Sessions0,I}=State) ->
    case Term of
        {error,_} = Err ->
            io:format("*DBG* ~p~n", [[{id,Id},Err]]);
        _ ->
            ok
    end,
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            %%io:format("*DBG* unknown_session: ~p~n", [Id]),
            {noreply,State};
        {_,Pid1,_} = T ->
            case lists:keyfind(Pid1, 2, Sessions0) of
                T ->
                    %% This session is at the front of the Pid1's pipeline so we
                    %% can send it directly.
                    Pid1 ! {http_pipe,Id,Term},
                    case endterm(Term) of
                        true ->
                            %% Avoid inserting into ETS table if we are going to
                            %% cleanup immediately aftwards.
                            Sessions = close_recv(Id, MsgTab, Sessions0),
                            {noreply,{MsgTab,Sessions,I}};
                        false ->
                            ets:insert(MsgTab, {{Id,recv}, Term}),
                            {noreply,State}
                    end;
                _ ->
                    ets:insert(MsgTab, {{Id,recv}, Term}),
                    {noreply,State}
            end
    end.

handle_info({'EXIT',Pid1,_Reason}, {MsgTab,Sessions0,I}) ->
    Sessions = exit_send(lists:keyfind(Pid1, 2, Sessions0),
                         MsgTab, Sessions0),
    {noreply, {MsgTab,Sessions,I}}.

endterm(eof) ->
    true;

endterm(_) ->
    false.

close_send(Id, MsgTab, Sessions0) ->
    %%{_,{_H,M,S}} = calendar:local_time(),
    %%io:format("~2..0B~2..0B [~B] (???) close_send~n", [M,S,Id]),

    %% After the last term is sent, we 'null' out the receiving
    %% Pid.  This is in case we need to send the messages
    %% again, due to failure. At the same, time we see if we
    %% cannot start sending the next batch of messages, as
    %% well.
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            %% Send end of the pipe may NOT ignore missing sessions.
            error(unknown_session);
        {_,Pid1,Pid2} ->
            Sessions1 = lists:keyreplace(Id, 1, Sessions0, {Id,Pid1,null}),
            Sessions2 = flush_send(Pid2, MsgTab, Sessions1),
            Sessions2
    end.

close_recv(Id, MsgTab, Sessions0) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            %% Recv end of the pipe may ignore missing sessions.
            Sessions0;
        {_,Pid1,_Pid2} ->
            Sessions1 = cleanup(Id, MsgTab, Sessions0),
            Sessions2 = flush_recv(Pid1, MsgTab, Sessions1),
            Sessions2
    end.

cleanup(Id, MsgTab, Sessions) ->
    ets:delete(MsgTab, {Id,send}),
    ets:delete(MsgTab, {Id,recv}),
    lists:keydelete(Id, 1, Sessions).

exit_send({Id,Pid1,_}, MsgTab, Sessions0) ->
    Sessions = cleanup(Id, MsgTab, Sessions0),
    exit_send(lists:keyfind(Pid1, 2, Sessions), MsgTab, Sessions);

exit_send(false, _MsgTab, Sessions) ->
    Sessions.

%%% Flushing sends *all* the messages that were stored in the ETS table for a
%%% specific pid.

flush_send(Pid2, MsgTab, Sessions0) ->
    case lists:keyfind(Pid2, 3, Sessions0) of
        false ->
            Sessions0;
        {Id,Pid1,_} ->
            Msgs = [Msg || {_,Msg} <- ets:lookup(MsgTab, {Id,send})],
            case sendall(Id, Pid2, Msgs) of
                true ->
                    Sessions = lists:keyreplace(Pid2, 3, Sessions0,
                                                {Id,Pid1,null}),
                    flush_send(Pid2, MsgTab, Sessions);
                false ->
                    Sessions0
            end
    end.

flush_recv(Pid1, MsgTab, Sessions0) ->
    case lists:keyfind(Pid1, 2, Sessions0) of
        false ->
            Sessions0;
        {Id,_,_Pid2} ->
            Msgs = [Msg || {_,Msg} <- ets:lookup(MsgTab, {Id,recv})],
            case sendall(Id, Pid1, Msgs) of
                true ->
                    Sessions = cleanup(Id, MsgTab, Sessions0),
                    flush_recv(Pid1, MsgTab, Sessions);
                false ->
                    Sessions0
            end
    end.

sendall(Id, Pid, [eof]) ->
    Pid ! {http_pipe,Id,eof},
    true;

sendall(_, _, []) ->
    false;

sendall(Id, Pid, [Msg|L]) ->
    Pid ! {http_pipe,Id,Msg},
    sendall(Id, Pid, L).
