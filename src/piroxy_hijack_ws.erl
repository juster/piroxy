-module(piroxy_hijack_ws).
-define(GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").
-record(state, {sid,relay}).
-include_lib("kernel/include/logger.hrl").

-export([start/1,calc_accept/1]).

%%%
%%% EXPORTS
%%%

start(Sid) ->
    Pid = spawn(fun () -> init(Sid) end),
    {ok,Pid}.

%%% Utility function to calculate the WebSocket accept header.
calc_accept(Key) ->
    Digest = crypto:hash(sha,[Key,?GUID]),
    base64:encode(Digest).

%%%
%%% INTERNALS
%%%

init(Sid) ->
    loop(#state{sid=Sid}).

loop(State0) ->
    receive
        Any ->
            io:format("*DBG* ~s ~p: received ~p~n", [?MODULE,self(),Any]),
            try handle(Any,State0) of
                State ->
                    loop(State)
            catch
                exit:Rsn ->
                    ?LOG_ERROR("~s exit reason: ~p", [?MODULE,Rsn]);
                error:Rsn:Stack ->
                    ?LOG_ERROR("~s error ~p", [?MODULE,{Rsn,Stack}])
            end
    end.

handle({connect,Pid,Reply}, S) ->
    link(Pid),
    Reply ! {connected,self()},
    S#state{relay=Pid};

handle({relay,Frame}, S) when is_tuple(Frame) ->
    handle_frame(Frame,S);

handle(Any, S) ->
    io:format("*DBG* ~s ~p: unexpected message: ~p~n",[?MODULE,self(),Any]),
    S.

handle_frame({ping,Bin}, S) ->
    %% respond to pings but do not generate them... yet
    reply({pong,Bin},S);

handle_frame({binary,Bin}, S0) ->
    %% all of our frames are binary
    Term = binary_to_term(Bin),
    io:format("*DBG* ~s ~p: received: ~p~n",[?MODULE,self(),Term]),
    {Res,S} = rpc(Term,S0),
    reply({binary,term_to_iovec(Res)},S),
    S;

handle_frame({close,L}, S) ->
    %% we need to send a close in response
    reply({close,L}, S),
    S;

handle_frame(_, S) ->
    %% ignore other frame types
    S.

rpc({echo,Term}, S) ->
    {Term,S};

rpc({filter,Filter}, S) ->
    {piroxy_ram_log:filter(Filter),S};

rpc(connections, S) ->
    {piroxy_ram_log:connections(),S};

rpc({log,ConnId}, S) ->
    {piroxy_ram_log:log(ConnId),S};

rpc({body,Digest}, S) ->
    {piroxy_ram_log:body(Digest),S};

rpc(_, _S) ->
    exit(badrpc).

reply(T, #state{sid=Sid,relay=Pid} = S) when is_tuple(T) ->
    piroxy_events:log(Sid,ws,recv,T),
    Pid ! {relay,T},
    S.
