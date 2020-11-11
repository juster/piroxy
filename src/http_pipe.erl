-module(http_pipe).
-behavior(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, start_shell/0, new/0, dump/0, send/2, listen/2, recv/2,
         reset/1, cancel/1]).
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

dump() ->
    gen_server:call(?MODULE, dump).

send(Id, Term) ->
    gen_server:cast(?MODULE, {send,Id,Term}).

listen(Id, Pid) ->
    gen_server:call(?MODULE, {listen,Id,Pid}).

reset(Id) ->
    gen_server:cast(?MODULE, {reset,Id}).

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

handle_call(dump, _From, {MsgTab,_,_}=State) ->
    {reply, ets:tab2list(MsgTab), State};

handle_call({listen,Id,Pid2}, _From, {MsgTab,Sessions0,I}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            {reply,{error,unknown_session},State};
        {_,Pid1,null} ->
            case lists:keyfind(Pid2, 3, Sessions0) of
                false ->
                    %% Ensure this is the first session for Pid2 and then send any
                    %% previously cached messages.
                    Msgs = [Msg || {_,Msg} <- ets:lookup(MsgTab, {Id,send})],
                    case sendall(Id, Pid2, Msgs) of
                        true ->
                            %% We sent all the messages and we do not need to
                            %% update the keylist (only to replace it with null).
                            {reply,ok,State};
                        false ->
                            %%link(Pid2),
                            Sessions = lists:keyreplace(Id, 1, Sessions0, {Id,Pid1,Pid2}),
                            {reply,ok,{MsgTab,Sessions,I}}
                    end;
                _ ->
                    %% This is not the first session for Pid2 and so we wait until it
                    %% has finished the previous one.
                    {reply,ok,State}
            end;
        {Id,_,Pid2} ->
            {reply,{error,{already_receiving,Id,Pid2}},State}
    end.

handle_cast({send, Id, Term}, {MsgTab,Sessions0,I}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            {noreply,State};
            %%{stop,{unknown_session,Id},State};
        {_,_,null} ->
            ets:insert(MsgTab, {{Id,send}, Term}),
            {noreply,State};
        {_,Pid1,Pid2} ->
            ets:insert(MsgTab, {{Id,send}, Term}),
            case lists:keyfind(Pid2, 3, Sessions0) of
                {Id,_,_} ->
                    %% If this is the first session in the pipeline then we do
                    %% not have to wait before we send it!
                    Pid2 ! {http_pipe,Id,Term},
                    case endterm(Term) of
                        true ->
                            %% We also close the send end of the pipe when an
                            %% 'eof' is received.
                            Sessions = close_send(Id, MsgTab, Sessions0),
                            {noreply, {MsgTab,Sessions,I}};
                        false ->
                            Sessions = lists:keyreplace(Id, 1, Sessions0, {Id,Pid1,Pid2}),
                            {noreply,{MsgTab,Sessions,I}}
                    end;
                _ ->
                    {noreply,State}
            end
    end;

handle_cast({cancel,Id}, {MsgTab,Sessions0,I}) ->
    Sessions = cleanup(Id, MsgTab, Sessions0),
    {noreply, {MsgTab,Sessions,I}};

%% reset the recv side of the pipe involves forgetting the receiving pid and
%% preparing for it to be replaced by a new one
handle_cast({reset,Id}, {MsgTab,Sessions0,I}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            {stop,unknown_session,State};
        {_,Pid1,_Pid2} = T ->
            case lists:keyfind(Pid1, 2, Sessions0) of
                T ->
                    %% This is the first session for Pid1 and so we must abort it.
                    %% We cannot be sure that some data has not already been piped
                    %% to Pid1. We have to break the pipeline to ensure responses
                    %% are not mangled together.
                    exit(Pid1, pipe_reset);
                _ ->
                    ets:delete(MsgTab, {recv,Id})
            end,
            Sessions = lists:keyreplace(Id, 1, Sessions0, {Id,Pid1,null}),
            {noreply,{MsgTab,Sessions,I}}
    end;

handle_cast({recv,Id,Term}, {MsgTab,Sessions0,I}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            {noreply,State};
            %%{stop,{unknown_session,Id},State};
        {_,Pid1,_} ->
            case lists:keyfind(Pid1, 2, Sessions0) of
                {Id,_,_} ->
                    %% This session is at the front of the Pid1's pipeline so we
                    %% can send it directly.
                    Pid1 ! {http_pipe,Id,Term},
                    case endterm(Term) of
                        true ->
                            Sessions = close_recv(Id, MsgTab, Sessions0),
                            {noreply,{MsgTab,Sessions,I}};
                        false ->
                            {noreply,State}
                    end;
                _ ->
                    %% Unlike with sends, we only cache received terms that
                    %% were not yet relayed.
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
    %% After the last term is sent, we 'null' out the receiving
    %% Pid.  This is in case we need to send the messages
    %% again, due to failure. At the same, time we see if we
    %% cannot start sending the next batch of messages, as
    %% well.
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            error(unknown_session);
        {_,Pid1,Pid2} ->
            Sessions1 = lists:keyreplace(Id, 1, Sessions0,
                                         {Id,Pid1,null}),
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

%% The send end of the pipe has exited. Send cancel messages to all linked recv
%% procs.
exit_send({Id,Pid1,_Pid2}, MsgTab, Sessions0) ->
    Sessions = cleanup(Id, MsgTab, Sessions0),
    exit_send(lists:keyfind(Pid1, 2, Sessions), MsgTab, Sessions);

exit_send(false, _MsgTab, Sessions) ->
    Sessions.

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
                    %% 'recv' messages must be deleted after they have been
                    %% sent!
                    ets:delete(MsgTab, {Id,recv}),
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
