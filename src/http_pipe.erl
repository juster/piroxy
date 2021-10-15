-module(http_pipe).
-behavior(gen_server).
-import(lists, [foreach/2]).
-include("../include/pihttp_lib.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0,start_shell/0,new/1,dump/0,sessions/0,
         send/2,listen/2,recv/2,recvall/2,close/1,rewind/1,
         cancel/1,transmit/3]).
-export([init/1, handle_call/3, handle_cast/2]).

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

new(Id) ->
    gen_server:call(?MODULE, {new,Id}).

sessions() ->
    gen_server:call(?MODULE, sessions).

dump() ->
    gen_server:call(?MODULE, dump).

send(Id, Term) ->
    piroxy_events:send(Id, http, Term),
    gen_server:cast(?MODULE, {send,Id,Term}).

listen(Id, Pid) ->
    gen_server:call(?MODULE, {listen,Id,Pid}).

rewind(Id) ->
    piroxy_events:fail(Id, http, rewind),
    gen_server:call(?MODULE, {rewind,Id}).

cancel(Id) ->
    piroxy_events:fail(Id, http, cancel),
    gen_server:cast(?MODULE, {cancel,Id}).

recv(Id, Term) ->
    piroxy_events:recv(Id, http, Term),
    gen_server:cast(?MODULE, {recv,Id,Term}).

recvall(Id, L) ->
    foreach(fun (Term) -> recv(Id, Term) end, L),
    close(Id).

close(Id) ->
    recv(Id, eof).

transmit(Pid,Id,Term) ->
    Pid ! {transmit,Id,Term}.

%%% BEHAVIOR CALLBACKS

init([]) ->
    process_flag(trap_exit, true),
    MsgTab = ets:new(?MODULE, [duplicate_bag,private]),
    {ok, {MsgTab, [], dict:new()}}.

handle_call({new,I}, {Pid,_Ref}, {MsgTab,Sessions0,Dict}) ->
    %%link(Pid),
    Sessions = Sessions0 ++ [{I,Pid,null}],
    {reply, ok, {MsgTab, Sessions, Dict}};

handle_call(sessions, _From, {_,Sessions,_}=State) ->
    {reply, Sessions, State};

handle_call(dump, _From, {MsgTab,_,_}=State) ->
    {reply, ets:tab2list(MsgTab), State};

%% The server end of the pipe starts to 'listen' for messages from the client
%% end.
handle_call({listen,Id,Pid2}, _From, {MsgTab,Sessions0,Dict0}=State) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            {reply,{error,unknown_session},State};
        {_,Pid1,_} ->
            %% Overwrite any old Pid2 entry in the session record.
            Sessions = lists:keyreplace(Id, 1, Sessions0, {Id,Pid1,Pid2}),
            case dict:is_key(Pid2, Dict0) of
                false ->
                    %% Ensure this is the first session for Pid2 and then send
                    %% any previously cached messages.
                    Msgs = [Msg || {_,Msg} <- ets:lookup(MsgTab, {Id,send})],
                    Dict = case sendall(Pid2,Id,Msgs) of
                               true ->
                                   Dict0;
                               false ->
                                   dict:store(Pid2, [Id], Dict0)
                           end,
                    {reply,ok,{MsgTab,Sessions,Dict}};
                true ->
                    %% This is not the first session for Pid2 and so we wait
                    %% until it has finished the previous one.
                    Dict = dict:append(Pid2, Id, Dict0),
                    {reply,ok,{MsgTab,Sessions,Dict}}
            end
    end;

%% Erase all the recv messages from the server-side of the pipe.
%% This is hard, because we must shutdown the http_req_sock proc if we can find
%% evidence that we have sent messages to http_req_sock for the purpose of
%% relaying them.
handle_call({rewind,Id}, _From, {MsgTab,Sessions0,Dict0}=State0) ->
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            %% Do not be strict on recv endpoints about whether a sessions
            %% disappears.
            {reply,cancel,State0};
        {_,_,null} ->
            %% this should not happen
            error(internal);
        {_,Pid1,Pid2}=T ->
            Dict = dict_delete(Pid2, Id, Dict0),
            Sessions = lists:keyreplace(Id, 1, Sessions0, {Id,Pid1,null}),
            State = {MsgTab,Sessions,Dict},
            case lists:keyfind(Pid1, 2, Sessions0) of
                T ->
                    %% We are unlucky, the client-side is currently blocking
                    %% on this session.
                    case ets:select(MsgTab, [{{{recv,Id},'_'},[],[found]}], 1) of
                        {[found],_} ->
                            %% We got unlucky and some messages were sent to the client-side.
                            %% Kill it! The process should cancel all of its requests.
                            ets:delete(MsgTab, {recv,Id}),
                            exit(Pid1, {shutdown,reset}),
                            {reply, cancel, flush_server(Pid2, State)};
                        {[],_} ->
                            %% We got lucky and no messages were sent to the client-side.
                            %% Now we must flush the server-side in case it has
                            %% another session after this one. Otherwise, we
                            %% will wait for it to send eof for a session it
                            %% just reset.
                            {reply, ok, flush_server(Pid2, State)};
                        '$end_of_table' ->
                            {reply, ok, flush_server(Pid2, State)}
                    end;
                _ ->
                    %% We are lucky, the client-side is blocking on some other session.
                    {reply,ok,State}
            end
    end.

handle_cast({send, Id, Term}, {MsgTab,Sessions,Dict0}=State) ->
    case lists:keyfind(Id, 1, Sessions) of
        false ->
            %% The session may no longer exist because EOF was recv-ed before
            %% the client had time to send the final EOF.
            {noreply,State};
        {_,_,null} ->
            ets:insert(MsgTab, {{Id,send}, Term}),
            {noreply,State};
        {_,_Pid1,Pid2} ->
            ets:insert(MsgTab, {{Id,send}, Term}),
            case dict:find(Pid2, Dict0) of
                error ->
                    io:format("*DBG* http_pipe: no entry for ~p~n", [Pid2]),
                    {stop,badstate,State};
                {ok,[]} ->
                    io:format("*DBG* http_pipe: empty list for ~p~n", [Pid2]),
                    {stop,badstate,State};
                {ok,[Id|L]} ->
                    %% If this is the first session in Pid2's pipeline then we do
                    %% not have to wait before we send it!
                    transmit(Pid2,Id,Term),
                    case Term of
                        eof ->
                            %% We also close the server end of the pipe when an
                            %% 'eof' is received.
                            Dict = case L of
                                       [] -> dict:erase(Pid2, Dict0);
                                       _ -> dict:store(Pid2, L, Dict0)
                                   end,
                            {noreply, flush_server(Pid2, {MsgTab,Sessions,Dict})};
                        _ ->
                            {noreply, {MsgTab,Sessions,Dict0}}
                    end;
                {ok,_} ->
                    {noreply,State}
            end
    end;

handle_cast({cancel,Id}, {_,Sessions,_}=State) ->
    case lists:keyfind(Id, 1, Sessions) of
        false ->
            {noreply, State};
        {_,_,null} = T ->
            %% We have not sent anything yet, we can cancel without anyone
            %% being the wiser!
            {noreply, cleanup(T, State)};
        {_,_,Pid2} = T ->
            %% Pid2 was likely sent some messages, which it has relayed.
            %% We must notify it so it can decide if it should shutdown.
            %% http_res_sock MAY exit at this point, but we don't know...
            transmit(Pid2,Id,cancel),
            {noreply, cleanup(T, State)}
    end;

handle_cast({recv,Id,Term}, {MsgTab,Sessions0,_}=State) ->
    %%case Term of
    %%    {error,_} = Err ->
    %%        io:format("*DBG* ~p~n", [[{id,Id},Err]]);
    %%    _ ->
    %%        ok
    %%end,
    case lists:keyfind(Id, 1, Sessions0) of
        false ->
            %%io:format("*DBG* unknown_session: ~p~n", [Id]),
            {noreply,State};
        {_,Pid1,_} = T ->
            case lists:keyfind(Pid1, 2, Sessions0) of
                T ->
                    %% This session is at the front of the Pid1's pipeline so we
                    %% can send it directly.
                    transmit(Pid1,Id,Term),
                    case Term of
                        eof ->
                            %% Avoid inserting into ETS table if we are going to
                            %% cleanup immediately aftwards.
                            {noreply, flush_client(Pid1, cleanup(T, State))};
                        _ ->
                            ets:insert(MsgTab, {{Id,recv}, Term}),
                            {noreply,State}
                    end;
                _ ->
                    ets:insert(MsgTab, {{Id,recv}, Term}),
                    {noreply,State}
            end
    end.

dict_delete(Pid2, Id, Dict) ->
    case dict:find(Pid2, Dict) of
        {ok,L0} ->
            case lists:delete(Id, L0) of
                [] -> dict:erase(Pid2, Dict);
                L -> dict:store(Pid2, L, Dict)
            end;
        error ->
            %% Pid2 may have finished receiving all messages.
            Dict
    end.

flush_server(Pid2, {MsgTab,Sessions,Dict0}=State) ->
    case dict:find(Pid2, Dict0) of
        {ok,[Id|L]} ->
            Msgs = [Msg || {_,Msg} <- ets:lookup(MsgTab, {Id,send})],
            case sendall(Pid2,Id,Msgs) of
                true ->
                    Dict = case L of
                               [] -> dict:erase(Pid2, Dict0);
                               _ -> dict:store(Pid2, L, Dict0)
                           end,
                    flush_server(Pid2, {MsgTab,Sessions,Dict});
                false ->
                    State
            end;
        error ->
            State
    end.

%%% Flushing sends *all* the messages that were stored in the ETS table for a
%%% specific client-side. When the client receives all of its messages, then
%%% we can delete the session.
flush_client(Pid1, {MsgTab,Sessions0,_}=State) ->
    case lists:keyfind(Pid1, 2, Sessions0) of
        false ->
            State;
        {Id,_,_Pid2}=T ->
            Msgs = [Msg || {_,Msg} <- ets:lookup(MsgTab, {Id,recv})],
            case sendall(Pid1,Id,Msgs) of
                true ->
                    flush_client(Pid1, cleanup(T, State));
                false ->
                    State
            end
    end.

%%% Low-level session cleanup function. Does not perform flushes.
cleanup({Id,_,Pid2}, {MsgTab,Sessions0,Dict0}) ->
    ets:delete(MsgTab, {Id,send}),
    ets:delete(MsgTab, {Id,recv}),
    Sessions = lists:keydelete(Id, 1, Sessions0),
    case Pid2 of
        null ->
            {MsgTab,Sessions,Dict0};
        _ ->
            {MsgTab,Sessions,dict_delete(Pid2, Id, Dict0)}
    end.

sendall(Pid,Sid,[eof]) ->
    transmit(Pid,Sid,eof),
    true;

sendall(_,_,[]) ->
    false;

sendall(Pid,Sid,[Msg|L]) ->
    transmit(Pid,Sid,Msg),
    sendall(Pid,Sid,L).
