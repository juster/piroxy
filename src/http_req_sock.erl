%%% http_req_sock
%%% State machine.
%%% Receives HTTP requests from the socket as binary.
%%% Sends HTTP responses, received from 'http_pipe' as tuples.

-module(http_req_sock).
-behavior(gen_statem).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-define(TIMEOUT, 15000).
%% TODO: move CONNECT_TIMEOUT here

-record(data, {target, socket, reader, queue=[], active}).
-export([start/0, stop/1, control/2]).
-export([init/1, terminate/2, callback_mode/0, handle_event/4]).

%%%
%%% EXTERNAL INTERFACE
%%%

start() ->
    gen_statem:start(?MODULE, [], []).

stop(Pid) ->
    try
        gen_statem:stop(Pid)
    catch
        exit:noproc -> ok
    end.

control(Pid, Socket) ->
    gen_statem:cast(Pid, {control,Socket}).

%%%
%%% BEHAVIOR CALLBACKS
%%%

callback_mode() -> [handle_event_function, state_enter].

init([]) ->
    {ok, connect, #data{}}.

terminate(_, D) ->
    Req = case D#data.active of undefined -> 0; _ -> D#data.active end,
    Host = case D#data.target of undefined -> "???"; _ -> element(2,D#data.target) end,
    Sock = element(1,D#data.socket),
    io:format("[~B] (~s) < inbound ~s socket closed~n", [Req, Host, Sock]),
    lists:foreach(fun (X) ->
                          piroxy_events:cancel(X, http)
                  end, D#data.queue).

%%%
%%% TIMEOUT
%%%

handle_event(enter, connect, _, _) ->
    {keep_state_and_data, {timeout,?CONNECT_TIMEOUT,connect}};

handle_event(enter, _, _, _) ->
    {keep_state_and_data, {timeout,?TIMEOUT,idle}};

handle_event(timeout, _, _, _) ->
    %% Use the idle timeout to automatically close.
    {stop, shutdown};

%%%
%%% RECEIVE THE SOCKET FROM PISERVER
%%%

%% only one event should happen in this state (or timeout, above)
handle_event(cast, {control,Sock}, connect, D) ->
    ok = inet:setopts(Sock, [{active,true}]),
    {next_state, head, D#data{socket={tcp,Sock}, reader=pimsg:head_reader()}};

%%%
%%% TCP/SSL messages
%%%

%% Ignore empty data but reset timer.
handle_event(info, {A,_,<<>>}, _, _)
  when A == tcp; A == ssl ->
    {keep_state_and_data, {timeout,?TIMEOUT,idle}};

handle_event(info, {A,_,Bin}, head, D)
  when A == tcp; A == ssl ->
    case pimsg:head_reader(D#data.reader, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            {keep_state,D#data{reader=Reader}};
        {done,StatusLn,Headers,Rest} ->
            H = head(StatusLn, Headers),
            recv_head(H, target(H), Rest, D)
    end;


handle_event(info, {A,_,Bin1}, body, D)
  when A == tcp; A == ssl ->
    case pimsg:body_reader(D#data.reader, Bin1) of
        {error,Reason} ->
            {stop,Reason};
        {continue,?EMPTY,Reader} ->
            {keep_state,D#data{reader=Reader}};
        {continue,Bin2,Reader} ->
            piroxy_events:send(D#data.active, http, {body,Bin2}),
            {keep_state,D#data{reader=Reader}};
        {done,Bin2,Rest} ->
            Req = D#data.active,
            case Bin2 of
                ?EMPTY -> ok;
                _ -> piroxy_events:send(Req, http, {body,Bin2})
            end,
            Host = case D#data.target of
                       undefined -> "???";
                       _ -> element(2,D#data.target)
                   end,
            ?TRACE(Req, Host, ">", "EOF"),
            piroxy_events:send(Req, http, eof),
            {next_state, head, D#data{reader=pimsg:head_reader()},
             {next_event,info,{A,null,Rest}}}
    end;

handle_event(info, {A,_}, _, _)
  when A == tcp_closed; A == ssl_closed ->
    {stop,shutdown};

handle_event(info, {A,_,Reason}, _, _)
  when A == tcp_error, A == ssl_error ->
    {stop,Reason};

%%%
%%% messages from http_pipe/piserver
%%%

handle_event(info, {http_pipe,Res,#head{}=Head}, _, D) ->
    %% pipeline the next request ASAP
    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
    ?TRACE(Res, Host, "<", Head),
    send(D#data.socket, Head);

handle_event(info, {http_pipe,Res,eof}, _, D) ->
    %% Avoid trying to encode the 'eof' atom.
    [Res|Q] = D#data.queue,
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    ?TRACE(Res, Host, "<", "EOF"),
    {keep_state, D#data{queue=Q}};

handle_event(info, {http_pipe,Res,Term}, _, D) ->
    case Term of
        {error,Rsn} ->
            Res = hd(D#data.queue),
            Host = case D#data.target of
                       undefined -> "???";
                       _ -> element(2,D#data.target)
                   end,
            %%io:format("*DBG* Res=~B~n", [Res]),
            Bin = iolist_to_binary(phttp:encode(Term)),
            Line = case binary:match(Bin, <<?CRLF>>) of
                       {Pos,_} ->
                           binary:part(Bin, 0, Pos);
                       _ ->
                           "???"
                   end,
            ?TRACE(Res, Host, "<<", io_lib:format("ERROR: ~p", [Rsn])),
            ?TRACE(Res, Host, "<", Line);
        _ ->
            ok
    end,
    send(D#data.socket, Term);

%%%
%%% TLS TUNNEL
%%%

handle_event(cast, {connect,HI}, tunnel, D) ->
    {https,Host,443} = HI,
    {tcp,TcpSock} = D#data.socket,
    [] = D#data.queue,
    case forger:mitm(TcpSock, Host) of
        {ok,TlsSock} ->
            {_,{_H,M,S}} = calendar:local_time(),
            io:format("~2..0B~2..0B [0] (~s) inbound ~p started tunnel~n",
                      [M,S,Host,self()]),
            {next_state, head, D#data{target=HI,
                                      reader=pimsg:head_reader(),
                                      socket={ssl,TlsSock}}};
        {error,closed} ->
            {stop,shutdown};
        {error,einval} ->
            {stop,shutdown};
        {error,Rsn} ->
            ?LOG_ERROR("~p mitm failed for ~s: ~p", [self(), Host, Rsn]),
            {stop,Rsn}
    end.

%%%
%%% INTERNAL FUNCTIONS
%%%

send({tcp,Sock}, Term) ->
    case gen_tcp:send(Sock, phttp:encode(Term)) of
        ok -> keep_state_and_data;
        {error,closed} -> {stop,shutdown};
        {error,einval} -> {stop,shutdown};
        {error,Rsn} -> {stop,Rsn}
    end;

send({ssl,Sock}, Term) ->
    case ssl:send(Sock, phttp:encode(Term)) of
        ok -> keep_state_and_data;
        {error,closed} -> {stop,shutdown};
        {error,einval} -> {stop,shutdown};
        {error,Rsn} -> {stop,Rsn}
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

recv_head(#head{method=connect}, {authority,HI}, Bin, D) ->
    %% CONNECT uses the "authority" form of URIs and so
    %% cannot be used with relativize/2.
    send(D#data.socket, {status,http_ok}),
    case Bin of
        ?EMPTY -> ok;
        _ -> exit({extra_tunnel_bytes,Bin})
    end,
    {next_state, tunnel, D, {next_event, cast, {connect,HI}}};

recv_head(#head{method=options}, self, Bin, D) ->
    %% OPTIONS * refers to the proxy itself. Create a fake response..
    %% TODO: not yet implemented
    send(D#data.socket, {status,http_ok}),
    {next_state, head, D#data{reader=pimsg:head_reader()},
     {next_event, info, {tcp,null,Bin}}};

recv_head(H, relative, Bin, D) ->
    %% HTTP header is for a relative URL. Hopefully this is inside of a
    %% CONNECT tunnel!
    HI = D#data.target,
    case HI of undefined -> exit(host_missing); _ -> ok end,
    relay_head(H, HI, Bin, D);

recv_head(H, {absolute,HI2}, Bin, D) ->
    case D#data.target of undefined -> ok; _ -> exit(host_connected) end,
    H2 = relativize(H),
    relay_head(H2, HI2, Bin, D).

relay_head(H, HI, Bin, D) ->
    {_,Host,_} = HI,
    Req = http_pipe:new(),
    Q = D#data.queue ++ [Req],
    piroxy_events:connect(Req, http, HI),
    piroxy_events:send(Req, http, H),
    ?TRACE(Req, Host, ">", H),
    {State, Reader} = case H#head.bodylen of
                          0 ->
                              ?TRACE(Req, Host, ">", "EOF"),
                              piroxy_events:send(Req, http, eof),
                              {head, pimsg:head_reader()};
                          _ ->
                              {body, pimsg:body_reader(H#head.bodylen)}
                      end,
    {next_state, State,
     D#data{reader=Reader, target=HI, queue=Q, active=Req},
     {next_event, info, {tcp,null,Bin}}}.

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

