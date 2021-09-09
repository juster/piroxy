%%% TLS certificate and private key forging server.

-module(forger).
-behavior(gen_server).
-include("../include/pihttp_lib.hrl").
-import(lists, [any/2]).

-export([start/1, start_link/1, stop/0, forge/1, mitm/2]).
-export([init/1, handle_call/3, handle_cast/2]).

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
    DerKey = public_key:der_encode('ECPrivateKey', Key),
    Opts = [{mode,binary}, {packet,0}, {verify,verify_none},
            {alpn_preferred_protocols,[<<"http/1.1">>]},
            {cert,HostCert}, {key,{'ECPrivateKey',DerKey}}],
    %%{ok,Timer} = timer:apply_after(?CONNECT_TIMEOUT, io, format, ["SSL handshake spoofing ~s timed out.", Host]),
    TlsSock = case ssl:handshake(TcpSock, Opts, ?CONNECT_TIMEOUT) of
                  {error,_}=Err3 ->
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
    case any(fun (undefined) -> true; (_) -> false end, [CaPath,KeyPath,Passwd]) of
        true -> {stop, badarg};
        false ->
            Tab = ets:new(?MODULE, [set,private]),
            case {file:read_file(CaPath), file:read_file(KeyPath)} of
                {{ok,CaPem},{ok,KeyPem}} ->
                    Cert = decode_pem(CaPem),
                    Key = decrypt_pem(KeyPem, Passwd),
                    process_flag(trap_exit, true),
                    {ok,{Cert,Key,Tab}};
                {{error,Rsn},_} ->
                    {stop, {cafile, Rsn}};
                {_,{error,Rsn}} ->
                    {stop, {keyfile, Rsn}}
            end
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

%%%
%%% INTERNAL FUNCTIONS
%%%

decode_pem(PemBin) ->
    [Entry] = public_key:pem_decode(PemBin),
    public_key:pem_entry_decode(Entry).

%% Decode a PEM binary of a single entry, which was encrypted with Passwd.
decrypt_pem(PemBin, Passwd) ->
    [Entry] = public_key:pem_decode(PemBin),
    public_key:pem_entry_decode(Entry, Passwd).
