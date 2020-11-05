-module(piserver).

-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").
-import(lists, [foreach/2]).

-export([start/2, start_link/2, stop/0, superserver/1, server/0, listen/2]).

start(Addr, Port) ->
    Pid = spawn(?MODULE, listen, [Addr,Port]),
    register(piserver, Pid),
    {ok,Pid}.

start_link(Addr, Port) ->
    Pid = spawn_link(?MODULE, listen, [Addr,Port]),
    register(piserver, Pid),
    {ok,Pid}.

stop() ->
    exit(whereis(piserver), stop),
    ok.

listen(_Addr, Port) ->
    case gen_tcp:listen(Port, [inet,{active,false},binary]) of
        {ok,Listen} ->
            superserver(Listen);
        {error,Reason} ->
            io:format("~p~n",{error,Reason}),
            exit(Reason)
    end.

superserver(Listen) ->
    case gen_tcp:accept(Listen) of
        {ok,Socket} ->
            Pid = spawn(?MODULE, server, []),
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! {start,Socket},
                    piserver:superserver(Listen);
                {error,Reason} ->
                    exit(Pid, kill),
                    exit(Reason)
            end,
            ok;
        {error,Reason} ->
            exit(Reason)
    end.

server() ->
    process_flag(trap_exit, true),
    {ok,Pid1} = http11_statem:start_link({?REQUEST_TIMEOUT,infinity}, []),
    Pid2 = pipipe:start_link(self()),
    receive
        {start,TcpSock} ->
            inet:setopts(TcpSock, [{active,true}]),
            loop({tcp,TcpSock}, Pid1, Pid2)
    end.

loop(Sock, Pid1, Pid2) ->
    loop(Sock, Pid1, Pid2, {null,null}).

loop(Sock, Pid1, Pid2, State) ->
    receive
        %% receive requests from the client and parse them out
        {tcp,_,Data} ->
            http11_statem:read(Pid1, Data),
            loop(Sock, Pid1, Pid2, State);
        {tcp_closed,_} ->
            %%?DBG("loop", tcp_closed),
            http11_statem:shutdown(Pid1, closed),
            loop(Sock, Pid1, Pid2, State);
        {tcp_error,_,Reason} ->
            ?DBG("loop", tcp_error),
            http11_statem:shutdown(Pid1, Reason),
            loop(Sock, Pid1, Pid2, State);
        {ssl,_,Data} ->
            http11_statem:read(Pid1, Data),
            loop(Sock, Pid1, Pid2, State);
        {ssl_closed,_} ->
            %%?DBG("loop", ssl_closed),
            http11_statem:shutdown(Pid1, closed),
            loop(Sock, Pid1, Pid2, State);
        {ssl_error,_,Reason} ->
            ?DBG("loop", ssl_error),
            http11_statem:shutdown(Pid1, Reason),
            loop(Sock, Pid1, Pid2, State);
        {http,Term} ->
            %%?DBG("loop", http),
            http(Sock, Pid1, Pid2, State, Term);
        {pipe,Req,Term} ->
            %%?DBG("loop", [{pipe,Req}]),
            send(Sock, phttp:encode(Term)),
            loop(Sock, Pid1, Pid2, State);
        {'EXIT',Pid,Reason} ->
            %%?DBG("loop", [{reason,Reason},{pid,Pid}]),
            exit(Reason);
        Any ->
            ?DBG("loop", [{unknown_message,Any}]),
            exit({unknown_message, Any})
    end.

http(Sock, Pid1, Pid2, {HI,_Req0}, {head,StatusLn,Headers}) ->
    H = head(StatusLn, Headers),
    http11_statem:expect_bodylen(Pid1, H#head.bodylen),
    case target(H) of
        {authority,HI2} ->
            %% Connect uses the "authority" form of URIs and so
            %% cannot be used with relativize/2.
            ok = send(Sock, phttp:encode({status,http_ok})),
            receive {http,eof} -> ok end,
            Sock2 = tunnel(Sock, HI2),
            loop(Sock2, Pid1, Pid2, {HI2,null});
        self ->
            %% OPTIONS * refers to the proxy itself
            %% TODO: not yet implemented, really
            %% Create a fake response.
            receive {http,eof} -> ok end,
            Req = request_manager:nextid(),
            pipipe:expect(Pid2, Req),
            pipipe:drip(Pid2, Req, {body,phttp:encode({status,http_ok})}),
            pipipe:drip(Pid2, Req, eof),
            loop(Sock, Pid1, Pid2, {HI,Req});
        relative ->
            %% HTTP header is for a relative URL. Hopefully this is inside of a
            %% CONNECT tunnel!
            case HI of
                null -> exit(host_missing);
                _ -> ok
            end,
            Req = request_manager:make(Pid2, HI, H),
            loop(Sock, Pid1, Pid2, {HI,Req});
        {absolute,HI2} ->
            case HI of
                null -> ok;
                _ -> exit(already_connected)
            end,
            Hrel = relativize(H),
            Req = request_manager:make(Pid2, HI2, Hrel),
            loop(Sock, Pid1, Pid2, {HI,Req})
    end;

http(Sock, Pid1, Pid2, {_,Req}=State, Term) ->
    morgue:append(Req, Term),
    loop(Sock, Pid1, Pid2, State).

send({tcp,Sock}, Bin) ->
    gen_tcp:send(Sock, Bin);

send({ssl,Sock}, Bin) ->
    ssl:send(Sock, Bin).

%% TODO: handle ssl sockets as well? (allows nested CONNECTs)
%% TODO: allow ports other than 443?
tunnel({tcp,TcpSock}, {https,Host,443}) ->
    case forger:mitm(TcpSock, Host) of
        {ok,TlsSock} ->
            {ssl,TlsSock};
        {error,closed} ->
            exit(closed);
        {error,einval} ->
            exit(closed);
        {error,Rsn} ->
            ?LOG_ERROR("~p mitm failed for ~s: ~p", [self(), Host, Rsn]),
            exit(Rsn)
    end.

head(StatusLn, Headers) ->
    Len = body_length(StatusLn, Headers),
    {ok,[MethodBin,_UriBin,VerBin]} = phttp:nsplit(3, StatusLn, <<" ">>),
    case {phttp:method_atom(MethodBin), phttp:version_atom(VerBin)} of
        {unknown,_} ->
            ?DBG("head", {unknown_method,MethodBin}),
            exit({unknown_method,MethodBin});
        {_,unknown} ->
            ?DBG("head", {unknown_version,VerBin}),
            exit({unknown_version,VerBin});
        {Method,Ver} ->
            #head{line=StatusLn, method=Method, version=Ver,
                  headers=Headers, bodylen=Len}
    end.

body_length(StatusLn, Headers) ->
    {ok,[MethodBin,_UriBin,VerBin]} = phttp:nsplit(3, StatusLn, <<" ">>),
    case phttp:version_atom(VerBin) of
        http11 ->
            ok;
        _ ->
            exit({unknown_version,VerBin})
    end,
    case phttp:method_atom(MethodBin) of
        unknown ->
            exit({unknown_method,MethodBin});
        Method ->
            case request_length(Method, Headers) of
                {error,Rsn} -> exit(Rsn);
                {ok,BodyLen} -> BodyLen
            end
    end.

request_length(connect, _) -> {ok,0};
request_length(get, _) -> {ok,0};
request_length(options, _) -> {ok,0};
request_length(_, Headers) -> pimsg:body_length(Headers).

%% Returns HostInfo ({Host,Port}) for the provided request HTTP message header.
%% If the Head contains a request to a relative URI, Host=null.
target(Head) ->
    UriBin = head_uri(Head),
    case {Head#head.method, UriBin} of
        {connect,_} ->
            {ok,[Host,Port]} = phttp:nsplit(2, UriBin, <<":">>),
            case Port of
                <<"443">> ->
                    {authority, {https,Host,binary_to_integer(Port)}};
                <<"80">> ->
                    %% NYI
                    {authority, {http,Host,binary_to_integer(Port)}};
                _ ->
                    exit(http_bad_request)
            end;
        {options,<<"*">>} ->
            self;
        {_,<<"/",_/binary>>} ->
            %% relative URI, hopefully we are already CONNECT-ed to a
            %% single host
            relative;
        _ ->
            case http_uri:parse(UriBin) of
                {error,{malformed_uri,_,_}} ->
                    exit(http_bad_request);
                {ok,{Scheme,_UserInfo,Host,Port,_Path0,_Query}} ->
                    %% XXX: never Fragment?
                    %% XXX: how to use UserInfo?
                    %% URI should be absolute when received from proxy client!
                    %% Convert to relative before sending to host.
                    {absolute, {Scheme,Host,Port}}
            end
    end.

head_uri(H) ->
    {ok,[_,UriBin,_]} = phttp:nsplit(3, H#head.line, <<" ">>),
    UriBin.

relativize(H) ->
    UriBin = head_uri(H),
    case http_uri:parse(UriBin) of
        {error,Rsn} -> Rsn;
        {ok,{_Scheme,_UserInfo,Host,_Port,Path0,Query}} ->
            case check_host(Host, H#head.headers) of
                {error,_} = Err -> Err;
                ok ->
                    MethodBin = phttp:method_bin(H#head.method),
                    Path = iolist_to_binary([Path0|Query]),
                    Line = <<MethodBin/binary," ",Path/binary," ", ?HTTP11>>,
                    H#head{line=Line}
            end
    end.

check_host(Host, Headers) ->
    case fieldlist:get_value(<<"host">>, Headers) of
        not_found ->
            {error,host_missing};
        Host ->
            ok;
        Host2 ->
            ?DBG("check_host", {host_mismatch,Host,Host2}),
            {error,{host_mismatch,Host2}}
    end.

