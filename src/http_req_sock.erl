%%% http_req_sock
%%% State machine.
%%% Receives HTTP requests from the socket as binary.
%%% Sends HTTP responses, received from 'http_pipe' as tuples.

-module(http_req_sock).
-behavior(gen_statem).
-import(lists, [reverse/1]).
-include("../include/pihttp_lib.hrl").
-include_lib("kernel/include/logger.hrl").

-define(IDLE_TIMEOUT, 5*60*1000).
-define(ACTIVE_TIMEOUT, 5000).

-record(data, {target, socket, reader, queue=[], active}).
-export([start/0, stop/1, control/2]).
-export([init/1, terminate/3, callback_mode/0, handle_event/4]).

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

terminate(Reason, _, D) ->
    Req = case D#data.active of undefined -> 0; _ -> D#data.active end,
    Host = case D#data.target of undefined -> "???"; _ -> element(2,D#data.target) end,
    ?TRACE(Req, Host, "<", io_lib:format("inbound closed: ~p", [Reason])),
    lists:foreach(fun (X) ->
                          request_manager:cancel(X),
                          http_pipe:cancel(X)
                  end, D#data.queue).

%%%
%%% TIMEOUT
%%%

handle_event(enter, connect, _, _) ->
    {keep_state_and_data, {state_timeout,?CONNECT_TIMEOUT,connect}};

handle_event(enter, idle, _, _) ->
    {keep_state_and_data, {state_timeout,?IDLE_TIMEOUT,idle}};

handle_event(enter, _, _, _) ->
    {keep_state_and_data, {state_timeout,?ACTIVE_TIMEOUT,active}};

handle_event(state_timeout, idle, _, _) ->
    %% Use the idle timeout to automatically close.
    {stop, shutdown};

handle_event(state_timeout, active, _, _) ->
    %% Similar to http_res_sock
    {stop, {shutdown,timeout}};

%%%
%%% RECEIVE THE SOCKET FROM PISERVER
%%%

%% Only the socket control event or a timeout event should happen in the
%% connect state.
handle_event(cast, {control,Sock}, connect, D) ->
    ok = inet:setopts(Sock, [{active,true}]),
    {next_state, idle, D#data{socket={tcp,Sock}}};

%%%
%%% TCP/SSL messages
%%%

%% Ignore empty data but reset timer.
handle_event(info, {A,_,?EMPTY}, idle, _)
  when A == tcp; A == ssl ->
    {keep_state_and_data, {state_timeout,?IDLE_TIMEOUT,idle}};

%%handle_event(info, {A,_,<<>>}, _, _)
%%  when A == tcp; A == ssl ->
%%    {keep_state_and_data, {state_timeout,?ACTIVE_TIMEOUT,active}};

handle_event(info, {A,_,_}, idle, D)
  when A == tcp; A == ssl ->
    {next_state, head, D#data{reader=pimsg_lib:head_reader()}, postpone};

handle_event(info, {A,_,Bin}, head, D)
  when A == tcp; A == ssl ->
    case pihttp_lib:head_reader(D#data.reader, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            %% Keep the 'head' state but reset the timer.
            {keep_state,D#data{reader=Reader},
             {state_timeout,?ACTIVE_TIMEOUT,active}};
        {done,StatusLn,Headers,Rest} ->
            %% head may throw an exit/error
            case head(StatusLn, Headers) of
                {ok,H} ->
                    handle_head(H, target(H), Rest, D);
                {error,Rsn} ->
                    {stop,Rsn,D}
            end
    end;

handle_event(info, {A,_,Bin1}, body, D)
  when A == tcp; A == ssl ->
    case pihttp_lib:body_reader(D#data.reader, Bin1) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Bin2,Reader} ->
            %% Keep the 'body' state but reset the timer.
            case Bin2 of
                ?EMPTY -> ok;
                _ ->
                    http_pipe:send(D#data.active, {body,Bin2})
            end,
            {keep_state,D#data{reader=Reader},
             {state_timeout,?ACTIVE_TIMEOUT,active}};
        {done,Bin2,Rest} ->
            Req = D#data.active,
            case Bin2 of
                ?EMPTY -> ok;
                _ -> http_pipe:send(Req, {body,Bin2})
            end,
            Host = case D#data.target of
                       undefined -> "???";
                       _ -> element(2,D#data.target)
                   end,
            ?TRACE(Req, Host, ">", "EOF"),
            http_pipe:send(Req, eof),
            {next_state, idle, D#data{reader=undefined},
             {next_event,info,{A,null,Rest}}}
    end;

%% Stall the pipeline while we are waiting for a response regarding the
%% upgrade.
handle_event(info, {A,_,Bin}, paused, D)
  when A == tcp; A == ssl ->
    L = D#data.reader,
    {keep_state, D#data{reader=[Bin|L]}};

handle_event(info, {A,_}, _, _)
  when A == tcp_closed; A == ssl_closed ->
    {stop,shutdown};

handle_event(info, {A,_,Reason}, _, _)
  when A == tcp_error, A == ssl_error ->
    {stop,Reason};

%%%
%%% messages from http_pipe/piserver
%%%

handle_event(info, {http_pipe,Res,{upgrade_socket,MFA}}, paused, D) ->
    case D#data.queue of
        [] ->
            error(underrun);
        [Res] ->
            %% Transfers the socket to the new process and shuts down.
            Bin = iolist_to_binary(reverse(D#data.reader)),
            {M,F,Opts} = MFA,
            case M:F(D#data.socket, Bin, Opts) of
                {ok,_} ->
                    {stop,shutdown};
                {error,Rsn} ->
                    error(Rsn)
            end;
        [Res|_] ->
            error(outoforder);
        _ ->
            error(overrun)
    end;

handle_event(info, {http_pipe,Res,eof}, paused, D) ->
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    case D#data.queue of
        [] ->
            error(request_underrun);
        [Res|Q] ->
            ?TRACE(Res, Host, "<", "EOF"),
            {keep_state, D#data{queue=Q}};
        [Res] ->
            %% If we get this far, an upgrade request did not result in a
            %% successful upgrade response (101). Restart the pipeline.
            ?TRACE(Res, Host, "<", "EOF"),
            Bin = iolist_to_binary(reverse(D#data.reader)),
            {next_state, idle,
             D#data{queue=[], reader=undefined, active=undefined},
             {next_event, info, {tcp,null,Bin}}}
    end;


handle_event(info, {http_pipe,Res,eof}, _, D) ->
    %% Avoid trying to encode the 'eof' atom. Pop the first response ID off the
    %% queue.
    [Res|Q] = D#data.queue,
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    ?TRACE(Res, Host, "<", "EOF"),
    {keep_state, D#data{queue=Q}};

handle_event(info, {http_pipe,_,{upgrade_socket,_,_}}, _, _) ->
    %% Ignore upgrade messages if we are not in the upgrade state.
    keep_state_and_data;

handle_event(info, {http_pipe,_,#head{}=Head}, paused, D) ->
    io:format("<====~n~s<~~~~~~~~~n", [pihttp_lib:encode(Head)]),
    send(D#data.socket, Head);

handle_event(info, {http_pipe,Res,#head{}=Head}, _, D) ->
    %% pipeline the next request ASAP
    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
    ?TRACE(Res, Host, "<", Head),
    send(D#data.socket, Head);

%%handle_event(info, {http_pipe,Req,reset}, _, D) ->
%%    case D#data.queue of
%%        [Req|_] ->
%%            %% Unfortunately we do not know if we have already
%%            %% sent any responses with send/2.
%%            {stop,shutdown};
%%        Q ->
%%            {keep_state, D#data{queue=lists:delete(Req, Q)}}
%%    end;

%% DEBUG TRACING
handle_event(info, {http_pipe,Res,{error,Rsn}=Term}, _, D) ->
    Res = hd(D#data.queue),
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    Bin = iolist_to_binary(pihttp_lib:encode(Term)),
    Line = case binary:match(Bin, <<?CRLF>>) of
               {Pos,_} ->
                   binary:part(Bin, 0, Pos);
               _ ->
                   "???"
           end,
    ?TRACE(Res, Host, "<<", io_lib:format("ERROR: ~p", [Rsn])),
    ?TRACE(Res, Host, "<", Line),
    send(D#data.socket, Term);

handle_event(info, {http_pipe,_Res,Term}, _, D) ->
    send(D#data.socket, Term);

%%%
%%% TLS TUNNEL
%%%

handle_event(cast, {connect,{http,Host,80}=HI}, tunnel, D) ->
    ?TRACE(0, Host, ">", <<"http_tunnel ",Host/binary>>),
    {next_state, idle, D#data{target=HI, reader=undefined}};

handle_event(cast, {connect,{https,Host,443}=HI}, tunnel, D) ->
    {tcp,TcpSock} = D#data.socket,
    [] = D#data.queue,
    case forger:mitm(TcpSock, Host) of
        {ok,TlsSock} ->
            ?TRACE(0, Host, ">", <<"https_tunnel ",Host/binary>>),
            %%io:format("~2..0B~2..0B [0] (~s) inbound ~p started tunnel~n",
            %%          [M,S,Host,self()]),
            {next_state, idle, D#data{target=HI,
                                      reader=undefined,
                                      socket={ssl,TlsSock}}};
        {error,closed} ->
            {stop,shutdown};
        {error,einval} ->
            {stop,shutdown};
        {error,Rsn} ->
            ?LOG_ERROR("~p mitm failed for ~s: ~p", [self(), Host, Rsn]),
            {stop,Rsn}
    end;

handle_event(cast, {connect,_}, tunnel, D) ->
    send(D#data.socket, {status,http_bad_gateway}),
    {next_state, idle, D}.

%%%
%%% INTERNAL FUNCTIONS
%%%

send(Sock, Term) ->
    %%io:format("~s----~n", [pihttp_lib:encode(Term)]),
    case pisock:send(Sock, pihttp_lib:encode(Term)) of
        ok -> keep_state_and_data;
        {error,closed} -> {stop,shutdown};
        {error,einval} -> {stop,shutdown};
        {error,Rsn} -> {stop,Rsn}
    end.

head(StatusLn, Headers) ->
    case pihttp_lib:split_status(request,StatusLn) of
        {ok,{Method,_Uri,Ver}} ->
            case request_length(Method,Headers) of
                {ok,Len} ->
                    {ok,#head{line=StatusLn,method=Method,version=Ver,headers=Headers,bodylen=Len}};
                {error,_} = Err ->
                    Err
            end;
        {error,_} = Err  ->
            Err
    end.

request_length(connect, _) -> {ok,0};
request_length(get, _) -> {ok,0};
request_length(options, _) -> {ok,0};
request_length(head, _) -> {ok,0};
request_length(_, Headers) -> pihttp_lib:body_length(Headers).

%% Returns HostInfo ({Host,Port}) for the provided request HTTP message header.
%% If the Head contains a request to a relative URI, Host=null.
target(Head) ->
    UriBin = head_uri(Head),
    case {Head#head.method, UriBin} of
        {connect,_} ->
            {ok,[Host,Port]} = pihttp_lib:nsplit(2, UriBin, <<":">>),
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
    {ok,[_,UriBin,_]} = pihttp_lib:nsplit(3, H#head.line, <<" ">>),
    UriBin.

handle_head(#head{method=connect}, {authority,HI}, Bin, D) ->
    %% CONNECT uses the "authority" form of URIs and so
    %% cannot be used with relativize/2.

    %% XXX: We MUST send the 200 OK reply here, first. When creating a
    %% fake HTTPS tunnel, we send the 200 OK unencrypted and then
    %% pretend to forward the TLS handshake to the host the client
    %% asked to be CONNECTed to.

    %% XXX: We cannot reply with {status,http_ok} because that will add
    %% a Content-Length header and a CONNECT reply "MUST NOT" have one.
    send(D#data.socket, {body,<<"HTTP/1.1 200 OK\015\012\015\012">>}),
    case Bin of
        ?EMPTY -> ok;
        _ -> exit({extra_tunnel_bytes,Bin})
    end,
    {next_state, tunnel, D, {next_event, cast, {connect,HI}}};

handle_head(#head{method=options}, self, Bin, D) ->
    %% OPTIONS * refers to the proxy itself. Create a fake response..
    %% TODO: not yet implemented
    send(D#data.socket, {status,http_ok}),
    {next_state, idle, D#data{reader=undefined},
     {next_event, info, {tcp,null,Bin}}};

handle_head(H, relative, Bin, D) ->
    %% HTTP header is for a relative URL. Hopefully this is inside of a
    %% CONNECT tunnel!
    HI = D#data.target,
    case HI of undefined -> exit(host_missing); _ -> ok end,
    relay_head(H, HI, Bin, D);

handle_head(H, {absolute,HI2}, Bin, D) ->
    %%case D#data.target of undefined -> ok; _ -> exit(host_connected) end,
    H2 = relativize(H),
    relay_head(H2, HI2, Bin, D).

connect_request(Req, HI, H) ->
    case piroxy_hijack:hijacked(HI, H) of
        true ->
            %% TODO: avoid using http_pipe to send to piroxy_hijack because
            %% it does not need to be pipelined on the server-side end
            piroxy_hijack:connect(Req, HI);
        false ->
            request_manager:connect(Req, HI)
    end.

relay_head(H, HI, Bin, D) ->
    {_,Host,_} = HI,
    Req = request_manager:nextid(),
    ok = http_pipe:new(Req),
    connect_request(Req, HI, H),
    http_pipe:send(Req, H),
    ?TRACE(Req, Host, ">", H),
    Q = D#data.queue ++ [Req],
    case {H#head.bodylen, upgrade_requested(H)} of
        {0,false} ->
            %% Skip ahead to the idle state when we do not expect to receive
            %% any body data.
            ?TRACE(Req, Host, ">", "EOF"),
            http_pipe:send(Req, eof),
            D2 = D#data{reader=undefined, target=HI, queue=Q, active=undefined},
            {next_state,idle,D2,{next_event,info,{tcp,null,Bin}}};
        {_,false} ->
            D2 = D#data{reader=pimsg_lib:body_reader(H#head.bodylen),
                        target=HI, queue=Q, active=Req},
            {next_state,body,D2,{next_event,info,{tcp,null,Bin}}};
        {0,true} ->
            %% An upgrade request stops the pipeline.
            %% Buffer any received binaries inside of reader.
            ?TRACE(Req, Host, ">", "PAUSE PIPELINE"),
            D2 = D#data{reader=[Bin], target=HI, queue=Q, active=Req},
            {next_state,paused,D2};
        _ ->
            %% Not sure what to do here...
            error(internal)
    end.

relativize(H) ->
    UriBin = head_uri(H),
    case http_uri:parse(UriBin) of
        {error,Rsn} -> Rsn;
        {ok,{_Scheme,_UserInfo,Host,_Port,Path0,Query}} ->
            case check_host(Host, H#head.headers) of
                {error,_} = Err -> Err;
                ok ->
                    MethodBin = pihttp_lib:method_bin(H#head.method),
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

upgrade_requested(H) ->
    Headers = H#head.headers,
    case fieldlist:get_value(<<"sec-websocket-key">>, Headers) of
        not_found -> ok;
        Key ->
            io:format("*DBG* ~p Sec-WebSocket-Key: ~s~n", [self(), Key])
    end,
    Conn = fieldlist:has_value(<<"connection">>, <<"upgrade">>, Headers),
    Upgrade = fieldlist:get_value(<<"upgrade">>, Headers),
    %%io:format("*DBG* Method=~s, Conn=~p, Upgrade=~s~n", [H#head.method, Conn, Upgrade]),
    case {H#head.method,Conn,Upgrade} of
        {_,_,not_found} ->
            false;
        {get,true,_} ->
            true;
        _ ->
            false
    end.

