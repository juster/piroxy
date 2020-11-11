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
    %%process_flag(trap_exit, true),
    {ok,Pid1} = http11_statem:start_link({?REQUEST_TIMEOUT,infinity}, []),
    receive
        {start,TcpSock} ->
            inet:setopts(TcpSock, [{active,true}]),
            loop({tcp,TcpSock}, Pid1)
    end.

loop(Sock, Pid1) ->
    loop(Sock, Pid1, {null,[],null}).

loop(Sock, Pid1, State) ->
    receive
        %% receive requests from the client and parse them out
        {tcp,_,Data} ->
            http11_statem:read(Pid1, Data),
            loop(Sock, Pid1, State);
        {tcp_closed,_} ->
            %%?DBG("loop", tcp_closed),
            Reqs = lists:join(",", [io_lib:format("~B", [R]) || R <- element(2,State)]),
            Host = case State of
                       {null,_,_} -> "???";
                       {{_,Host_,_},_,_} -> Host_
                   end,
            io:format("[~s] (~s) ~p inbound tcp closed~n", [Reqs, Host, self()]),
            cancelall(element(2,State)),
            http11_statem:shutdown(Pid1, cancel),
            loop(Sock, Pid1, State);
        {tcp_error,_,Reason} ->
            ?DBG("loop", tcp_error),
            http11_statem:shutdown(Pid1, Reason),
            loop(Sock, Pid1, State);
        {ssl,_,Data} ->
            http11_statem:read(Pid1, Data),
            loop(Sock, Pid1, State);
        {ssl_closed,_} ->
            Reqs = lists:join(",", [io_lib:format("~B", [R]) || R <- element(2,State)]),
            Host = element(2,element(1,State)),
            io:format("[~s] (~s) ~p inbound ssl closed~n", [Reqs, Host, self()]),
            %%?DBG("loop", ssl_closed),
            cancelall(element(2,State)),
            http11_statem:shutdown(Pid1, cancel),
            loop(Sock, Pid1, State);
        {ssl_error,_,Reason} ->
            ?DBG("loop", ssl_error),
            http11_statem:shutdown(Pid1, Reason),
            loop(Sock, Pid1, State);
        {http,Term} ->
            %%?DBG("loop", http),
            http(Sock, Pid1, State, Term);
        %% message from http_pipe/outbound
        {http_pipe,Res,eof} ->
            {HI,Reqs,Req} = State,
            %% Pop the top request off the stack.
            Host = case HI of
                null -> "???";
                {_,Host_,_} -> Host_
            end,
            ?TRACE(Res, Host, "<", "EOF"),
            loop(Sock, Pid1, {HI,tl(Reqs),Req});
        {http_pipe,Res,Term} ->
            %%?DBG("loop", [{pipe,Res}]),
            case Term of
                #head{} ->
                    Host = case element(1,State) of null -> "???"; {_,Host_,_} -> Host_ end,
                    ?TRACE(Res, Host, "<", Term);
                _ ->
                    ok
            end,
            send(Sock, phttp:encode(Term)),
            loop(Sock, Pid1, State);
        Any ->
            ?DBG("loop", [{unknown_message,Any}]),
            exit({unknown_message, Any})
    end.

http(Sock, Pid1, {HI,Reqs,_}, {head,StatusLn,Headers}) ->
    H = head(StatusLn, Headers),
    http11_statem:expect_bodylen(Pid1, H#head.bodylen),
    case target(H) of
        {authority,HI2} ->
            %% Connect uses the "authority" form of URIs and so
            %% cannot be used with relativize/2.
            send(Sock, phttp:encode({status,http_ok})),
            receive {http,eof} -> ok end,
            Sock2 = tunnel(Sock, HI2),
            loop(Sock2, Pid1, {HI2,Reqs,null});
        self ->
            %% OPTIONS * refers to the proxy itself
            %% TODO: not yet implemented, really
            %% Create a fake response.
            receive {http,eof} -> ok end,
            send(Sock, phttp:encode({status,http_ok})),
            loop(Sock, Pid1, {HI,Reqs});
        relative ->
            %% HTTP header is for a relative URL. Hopefully this is inside of a
            %% CONNECT tunnel!
            case HI of
                null -> exit(host_missing);
                _ -> ok
            end,
            Req = http_pipe:new(),
            ?TRACE(Req, element(2,HI), ">", H),
            piroxy_events:connect(Req, http, HI),
            piroxy_events:send(Req, http, H),
            loop(Sock, Pid1, {HI,Reqs++[Req],Req});
        {absolute,HI2} ->
            case HI of
                null -> ok;
                _ -> exit(already_connected)
            end,
            Hrel = relativize(H),
            Req = http_pipe:new(),
            piroxy_events:connect(Req, http, HI2),
            piroxy_events:send(Req, http, Hrel),
            Host = fieldlist:get_value(<<"host">>, Hrel#head.headers),
            ?TRACE(Req, Host, ">", Hrel),
            loop(Sock, Pid1, {HI,Reqs++[Req],Req})
    end;

http(Sock, Pid1, {_,_,Req}=State, Term) ->
    piroxy_events:send(Req, http, Term),
    loop(Sock, Pid1, State).

send({tcp,Sock}, Bin) ->
    case gen_tcp:send(Sock, Bin) of
        ok -> ok;
        {error,Rsn} -> exit(Rsn)
    end;

send({ssl,Sock}, Bin) ->
    case ssl:send(Sock, Bin) of
        ok -> ok;
        {error,Rsn} -> exit(Rsn)
    end.

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

cancelall(Reqs) ->
    lists:foreach(fun (Req) ->
                          piroxy_events:fail(Req, http, cancelled)
                  end, Reqs).
