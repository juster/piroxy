%%% TLS certificate and private key forging server.

-module(forger).
-behavior(gen_server).
-include("../include/pihttp_lib.hrl").

-export([start/1,start_link/1,stop/0,forge/1,lookup/1,mitm/2]).
-export([init/1,terminate/2,handle_call/3,handle_cast/2]).

%%%
%%% EXPORTS
%%%

start(Opts) ->
    gen_server:start({local,?MODULE}, ?MODULE, [Opts], []).

start_link(Opts) ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [Opts], []).

stop() ->
    gen_server:stop(?MODULE).

forge(Host) ->
    gen_server:call(?MODULE, {forge,Host}).

lookup(Host) ->
    gen_server:call(?MODULE,{lookup_cert,Host}).

mitm(TcpSock, Host) ->
    try mitm_(TcpSock, Host)
    catch Err -> Err
    end.

mitm_(TcpSock, Host) ->
    case inet:setopts(TcpSock, [{active,false}]) of
        %% socket may have suddenly closed!
        {error,_}=Err1 -> throw(Err1);
        ok -> ok
    end,
    {HostCert,Key,_CaCert} = case forge(Host) of
                                 {error,_}=Err2 -> throw(Err2);
                                 {ok,T} -> T
                             end,
    DerKey = public_key:der_encode(element(1,Key), Key),
    Opts = [{packet,0},
            {mode,binary},
            {cert,HostCert},
            {verify,verify_none},
            {key,{element(1,Key),DerKey}},
            {alpn_preferred_protocols,[<<"http/1.1">>]}],
    %%{ok,Timer} = timer:apply_after(?CONNECT_TIMEOUT, io, format, ["SSL handshake spoofing ~s timed out.", Host]),
    TlsSock = case ssl:handshake(TcpSock,Opts,?CONNECT_TIMEOUT) of
                  {error,_} = Err3 ->
                      throw(Err3);
                  {ok,X} ->
                      X
              end,
    %% XXX: active does not always work when provided to handshake/2
    ssl:setopts(TlsSock, [{active,true}]),
    {ok,TlsSock}.

%%%
%%% BEHAVIOR CALLBACKS
%%%

init([Opts]) ->
    CaPath = proplists:get_value(cafile, Opts),
    KeyPath = proplists:get_value(keyfile, Opts),
    Passwd = proplists:get_value(passwd, Opts),
    case lists:any(fun (undefined) -> true; (_) -> false end,
                   [CaPath,KeyPath,Passwd]) of
        true -> {stop, badarg};
        false ->
            Tab = ets:new(?MODULE, [set,private]),
            case {file:read_file(CaPath), file:read_file(KeyPath)} of
                {{ok,CaPem},{ok,KeyPem}} ->
                    Cert = decode_pem1(CaPem),
                    Key = decrypt_pem1(KeyPem, Passwd),
                    process_flag(trap_exit, true),
                    {ok,{Cert,Key,Tab}};
                {{error,Rsn},_} ->
                    {stop, {cafile, Rsn}};
                {_,{error,Rsn}} ->
                    {stop, {keyfile, Rsn}}
            end
    end.

terminate(_, {_,_,Tab}) ->
    ets:delete(Tab).

handle_call({forge,Host}, _From, {CaCert,PriKey,Tab}=State) ->
    %% TODO: automatically expire & cleanup pairs
    {HostCert,HostKey} = case ets:lookup(Tab, Host) of
                             [] ->
                                 T = forger_lib:forge([Host], {CaCert,PriKey}),
                                 ets:insert(Tab, {Host,T}),
                                 T;
                             [{_,T}] -> T
                         end,
    {reply, {ok,{HostCert,HostKey,CaCert}}, State};

handle_call({lookup_cert,Host}, _From, {_,_,Tab} = State) ->
    case ets:lookup(Tab,Host) of
        [] ->
            {reply,{ok,notfound},State};
        [{_,{Cert,_}}] ->
            {reply,{ok,Cert},State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%%
%%% INTERNAL FUNCTIONS
%%%

decode_pem1(PemBin) ->
    [Entry] = public_key:pem_decode(PemBin),
    public_key:pem_entry_decode(Entry).

%% Decode a PEM binary of a single entry, which was encrypted with Passwd.
decrypt_pem1(PemBin, Passwd) ->
    [Entry] = public_key:pem_decode(PemBin),
    public_key:pem_entry_decode(Entry, Passwd).
