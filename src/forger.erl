%%% TLS certificate and private key forging server.

-module(forger).
-behavior(gen_server).
-include("../include/phttp.hrl").
-import(lists, [any/2]).

-export([start/1, start_link/1, stop/0, forge/1]).
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
