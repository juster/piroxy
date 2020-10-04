%% TLS connection man-in-the-middle server.

-module(mitm).
-behavior(gen_server).

-export([bridge/3]).
-export([init/1, handle_call/3, handle_cast/2]).

%%%
%%% EXPORTS
%%%

bridge(Sock, Host, Port) ->
    %% handle timeout elsewhere
    gen_server:call(?MODULE, {bridge,Sock,Host,Port}, infinity).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([Opts]) ->
    Tab = ets:init(?MODULE, [private]),
    {Timeout,Passwd,KeyPath} =
    try
        {_,A} = lists:keyfind(timeout,Opts),
        {_,B} = lists:keyfind(passwd,Opts),
        {_,C} = lists:keyfind(keypath,Opts),
        {A,B,C}
    catch
        error:badmatch -> exit(badarg)
    end,

    PriKey = forger_lib:decode_private(KeyPath, Passwd),
    process_flag(trap_exit, true),
    {ok,{Timeout,PriKey,Tab}}.

handle_call({bridge,TcpSock,Host,Port}, {_Ref,Pid1}, State) ->
    Timeout = element(1,State),
    %% TODO: do this asynchronously
    {Cert,PriKey} = host_key_pair(Host, State),
    case ssl:connect(TcpSock,
                     [{active,false},binary,{cert,Cert},{key,PriKey}], Timeout) of
        {error,_}=Err1 -> {reply,Err1,State};
        {ok,TlsSock1} ->
            %% XXX: should the timeout be adjusted?
            case ssl:connect(Host, Port, [{active,false},binary,{packet,0}], Timeout) of
                {error,_}=Err2 ->
                    ssl:close(TlsSock1),
                    {reply,Err2,State};
                {ok,TlsSock2} ->
                    %% start will take control and set active
                    Pid2 = spawn(fun () -> start(Pid1, TlsSock2) end),
                    %% assign control to caller and set active
                    ssl:controlling_process(TlsSock1, Pid1),
                    ssl:setopts(TlsSock1, [{active,true}]),
                    {reply,{TlsSock1,Pid2},State}
            end
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

start(Pid, Sock) ->
    %% XXX: can any process take control?
    ssl:controlling_process(Sock, self()),
    ssl:setopts(Sock, [{active,true}]),
    loop(Pid, Sock).

loop(Pid, Sock) ->
    receive
        mitm_closed ->
            ssl:shutdown(Sock, read_write),
            loop(Pid, Sock); % loop for ssl_closed
        {mitm_data,Data} ->
            ssl:send(Sock, Data),
            loop(Pid, Sock);
        {ssl,Data} ->
            Pid ! {mitm_data,Data},
            loop(Pid, Sock);
        {ssl_error,_,Reason} ->
            Pid ! {mitm_error,Reason},
            {error,Reason};
        {ssl_closed,_} ->
            Pid ! mitm_closed,
            ok
    end.

host_key_pair(Host, {_,PriKey,Tab}) ->
    %% TODO: automatically expire & cleanup pairs
    case ets:lookup(Tab, Host) of
        [] ->
            T = forger_lib:forge([Host], PriKey),
            ok = ets:insert(Tab, {Host,T}),
            T;
        [T] -> T
    end.
