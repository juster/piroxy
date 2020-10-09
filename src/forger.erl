%%% TLS certificate and private key forging server.

-module(forger).
-behavior(gen_server).
-include("../include/phttp.hrl").
-import(lists, [any/2]).

-export([start/1, forge/1]).
-export([init/1, handle_call/3, handle_cast/2]).

%%%
%%% EXPORTS
%%%

start(Opts) ->
    gen_server:start({local,?MODULE}, ?MODULE, [Opts], []).

forge(Host) ->
    gen_server:call(?MODULE, {forge,Host}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([Opts]) ->
    Passwd = proplists:get_value(passwd, Opts),
    PemPath = proplists:get_value(keyfile, Opts),
    case any(fun (undefined) -> true; (_) -> false end,
             [Passwd,PemPath]) of
        true -> exit(badarg);
        false -> ok
    end,
    Tab = ets:new(?MODULE, [set,private]),
    case file:read_file(PemPath) of
        {ok,PemBin} ->
            {Cert,Key} = forger_lib:decode_ca_pair(PemBin, Passwd),
            process_flag(trap_exit, true),
            {ok,{Cert,Key,Tab}};
        {error,_}=Err ->
            Err
    end.

handle_call({forge,Host}, _From, {CaCert,PriKey,Tab}=State) ->
    %% TODO: automatically expire & cleanup pairs
    {HostCert,HostKey} = case ets:lookup(Tab, Host) of
                             [] ->
                                 T = forger_lib:forge([Host], {CaCert,PriKey}),
                                 ets:insert(Tab, {Host,T}),
                                 T;
                             [{_,T}] -> T
                         end,
    {reply, {ok,{HostCert,HostKey,CaCert}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
