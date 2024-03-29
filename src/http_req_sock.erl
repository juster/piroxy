%%% http_req_sock
%%% State machine.
%%% Receives HTTP requests from the socket as binary.
%%% Sends HTTP responses, received transmit messages from http_pipe.

-module(http_req_sock).
-behavior(gen_statem).
-include("../include/pihttp_lib.hrl").
-include_lib("kernel/include/logger.hrl").

-define(IDLE_TIMEOUT, 5*60*1000).
-define(ACTIVE_TIMEOUT, ?IDLE_TIMEOUT).
%%-define(ACTIVE_TIMEOUT, 5000).

-record(data, {target, socket, reader, queue=[], active}).
-export([start/0,stop/1,control/2]).
-export([init/1,terminate/3,callback_mode/0,handle_event/4]).

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
    keep_state_and_data;

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
    {next_state, head, D#data{reader=pihttp_lib:head_reader()}, postpone};

handle_event(info, {A,_,Bin}, head, D)
  when A == tcp; A == ssl ->
    case pihttp_lib:head_reader(D#data.reader, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            %% Keep the 'head' state but reset the timer.
            %%io:format("*DBG* head_reader continue after: ~p", [Bin]),
            {keep_state,D#data{reader=Reader},
             {state_timeout,?ACTIVE_TIMEOUT,active}};
        {done,StatusLn,Headers,Rest} ->
            %%io:format("*DBG* head_reader done~n"),
            case request_headuri(StatusLn, Headers) of
                {ok,{H,Uri}} ->
                    case head_target(H,Uri) of
                        {ok,Target} ->
                            handle_head(H,Target,Rest,D);
                        {error,Rsn} ->
                            {stop,Rsn,D}
                    end;
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

handle_event(info, {transmit,Res,{upgrade_socket,Pid2,Opts1}}, paused, D) ->
    case D#data.queue of
        [] ->
            {stop,underrun};
        [Res] ->
            #data{socket=Sock} = D,
            Bin = lists:reverse(D#data.reader),
            Logging = case proplists:get_value(mode,Opts1) of
                          ws ->
                              send;
                          raw ->
                              false
                      end,
            Opts2 = [{socket,Sock},{id,Res},{logging,Logging},{buffer,Bin}|Opts1],
            case ws_sock:start(Opts2) of
                {ok,Pid1} ->
                    case ws_sock:connect(Pid1,Pid2) of
                        ok ->
                            Mode = proplists:get_value(mode,Opts1),
                            piroxy_events:close(Res,http),
                            piroxy_events:connect(Res,Mode,D#data.target),
                            {stop,shutdown,D#data{queue=[]}};
                        {error,Rsn} ->
                            {stop,Rsn}
                    end;
                {error,Rsn} ->
                    {stop,Rsn}
            end;
        [Res|_] ->
            {stop,outoforder};
        _ ->
            {stop,overrun}
    end;

handle_event(info, {transmit,Res,eof}, paused, D) ->
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    case D#data.queue of
        [] ->
            {stop,underrun};
        [Res|Q] ->
            ?TRACE(Res, Host, "<", "EOF"),
            {keep_state,D#data{queue=Q}};
        [Res] ->
            %% If we get this far, an upgrade request did not result in a
            %% successful upgrade response (101). Restart the pipeline.
            ?TRACE(Res, Host, "<", "EOF"),
            Bin = iolist_to_binary(lists:reverse(D#data.reader)),
            {next_state,idle,
             D#data{queue=[],reader=undefined,active=undefined},
             {next_event,info,{tcp,null,Bin}}}
    end;


handle_event(info, {transmit,Res,eof}, _, #data{queue=[Res|Q]} = D) ->
    %% Avoid trying to encode the 'eof' atom. Pop the first response ID off the
    %% queue. eof must be received in order?
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    ?TRACE(Res, Host, "<", "EOF"),
    {keep_state,D#data{queue=Q}};

handle_event(info, {transmit,_,eof}, _, _) ->
    {stop,outoforder};

handle_event(info, {transmit,_,#head{}=Head}, paused, D) ->
    io:format("<====~n~s<~~~~~~~~~n", [pihttp_lib:encode(Head)]),
    send(D#data.socket, Head);

handle_event(info, {transmit,Res,#head{}=Head}, _, D) ->
    %% pipeline the next request ASAP
    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
    ?TRACE(Res, Host, "<", Head),
    send(D#data.socket, Head);

%%handle_event(info, {transmit,Req,reset}, _, D) ->
%%    case D#data.queue of
%%        [Req|_] ->
%%            %% Unfortunately we do not know if we have already
%%            %% sent any responses with send/2.
%%            {stop,shutdown};
%%        Q ->
%%            {keep_state, D#data{queue=lists:delete(Req, Q)}}
%%    end;

handle_event(info, {transmit,Res,{error,Rsn}=Term}, _, D) ->
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

handle_event(info, {transmit,_Res,Term}, _, D) ->
    send(D#data.socket, Term).

%%%
%%% INTERNAL FUNCTIONS
%%%

send(Sock, Term) ->
    %%io:format("~s----~n", [pihttp_lib:encode(Term)]),
    case pisock_lib:send(Sock, pihttp_lib:encode(Term)) of
        ok -> keep_state_and_data;
        {error,closed} -> {stop,shutdown};
        {error,einval} -> {stop,shutdown};
        {error,Rsn} -> {stop,Rsn}
    end.

%% Assemble a #head{} record and separates out the URI while we are at it.
request_headuri(StatusLn, Headers) ->
    case pihttp_lib:split_request_line(StatusLn) of
        {ok,{Method,Uri,Ver}} ->
            case request_length(Method,Headers) of
                {ok,Len} ->
                    H = #head{line=StatusLn,method=Method,version=Ver,headers=Headers,bodylen=Len},
                    {ok,{H,Uri}};
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

head_target(#head{method=connect},UriBin) ->
    case pihttp_lib:nsplit(2, UriBin, <<":">>) of
        {ok,[Host,<<"443">>]} ->
            {ok,{authority,{https,Host,443}}};
        {ok,[Host,<<"80">>]} ->
            %% NYI?
            {ok,{authority,{http,Host,80}}};
        {ok,[Host,PortBin]} ->
            Port = binary_to_integer(PortBin),
            {ok,{authority,{http,Host,Port}}};
        {error,_} = Err ->
            Err
    end;

head_target(#head{method=options},<<"*">>) ->
    %% This is a request to list the OPTIONs supported by the proxy (that's us!)
    {ok,self};

head_target(_,<<"/",_/binary>> = UriBin) ->
    %% There is no host specified and so this is considered a relative target.
    %% Hopefully we are already CONNECT-ed to a single host.
    {ok,{relative,UriBin}};

head_target(_,UriBin) ->
    {ok,{absolute,UriBin}}.

handle_head(#head{method=connect},{authority,T},Bin,D) ->
    %% CONNECT uses the "authority" form of URIs and so
    %% cannot be used with relativize/2.

    %% We MUST send the 200 OK reply here, first. When creating a
    %% fake HTTPS tunnel, we send the 200 OK unencrypted and then
    %% pretend to forward the TLS handshake to the host the client
    %% asked to be CONNECTed to.

    %% We cannot reply with {status,http_ok} because that will add
    %% a Content-Length header and a CONNECT reply "MUST NOT" have one.
    case T of
        {_,_,_} ->
            send(D#data.socket, {body,<<"HTTP/1.1 200 OK\015\012\015\012">>}),
            case Bin of
                ?EMPTY -> ok;
                _ -> exit({extra_tunnel_bytes,Bin})
            end,
            connect_tunnel(T,D);
        _ ->
            {stop,{badarg,{authority,T}}}
    end;

handle_head(#head{method=options},self,Bin, D) ->
    %% OPTIONS * refers to the proxy itself. Create a fake response..
    %% TODO: not yet implemented
    send(D#data.socket, {status,http_ok}),
    {next_state, idle, D#data{reader=undefined},
     {next_event, info, {tcp,null,Bin}}};

handle_head(H,{relative,RelUri},Bin,D) ->
    %% HTTP header is for a relative URL. Hopefully this is inside of a
    %% CONNECT tunnel!
    case D#data.target of
        undefined ->
            {stop,need_connect,D};
         HI ->
            Uri = case HI of
                      {http,Host,80} ->
                          <<"http://",Host/binary,RelUri/binary>>;
                      {https,Host,443} ->
                          <<"https://",Host/binary,RelUri/binary>>;
                      {Scheme,Host,Port} ->
                          SchemeBin = atom_to_binary(Scheme, latin),
                          PortBin = integer_to_binary(Port),
                          <<SchemeBin/binary,"://",Host/binary,":",PortBin/binary>>
                  end,
            relay_head(H,HI,Uri,Bin,D)
    end;

handle_head(H,{absolute,Uri},Bin,D) ->
    %%case D#data.target of undefined -> ok; _ -> exit(host_connected) end,
    case uri_string:parse(Uri) of
        {error,_} = Err ->
            {stop,Err,D};
        UriMap ->
            case relativize(H,UriMap) of
                {ok,H2} ->
                    relay_head(H2,urimap_hostinfo(UriMap),Uri,Bin,D);
                {error,Rsn} ->
                    {stop,Rsn,D}
            end
    end.

%%%
%%% TLS TUNNEL
%%%

connect_tunnel({http,Host,_} = HI, D) ->
    ?TRACE(0, Host, ">", <<"http_tunnel ",Host/binary>>),
    {next_state, idle, D#data{target=HI, reader=undefined}};

connect_tunnel({https,_,443}, #data{socket={ssl,_}}) ->
    {stop,already_tunneled};

connect_tunnel({https,Host,443} = HI, #data{socket={tcp,Sock}} = D) ->
    %% TODO: cleanup messy sanity check
    case D#data.queue of
        [] ->
            ok;
        _ ->
            error(need_empty_pipeline)
    end,
    case forger:mitm(Sock, Host) of
        {ok,TlsSock} ->
            ?TRACE(0, Host, ">", <<"connect_tunnel started">>),
            %%io:format("~2..0B~2..0B [0] (~s) inbound ~p started tunnel~n",
            %%          [M,S,Host,self()]),
            {next_state,
             idle,
             D#data{target=HI,reader=undefined,socket={ssl,TlsSock}}};
        {error,closed} ->
            {stop,shutdown};
        {error,einval} ->
            {stop,shutdown};
        {error,Rsn} ->
            ?LOG_ERROR("~p mitm failed for ~s: ~p", [self(),Host,Rsn]),
            {stop,Rsn}
    end;

%% Cowardly refuse to https tunnel for ports other than 443. This is a difficult
%% design problem because we do not know if a CONNECT tunnel should be encrypted
%% unless it is port 443!!
connect_tunnel(_, D) ->
    send(D#data.socket, {status,http_bad_gateway}),
    {next_state,idle,D}.


connect_request(Req, HI, H, Uri) ->
    case piroxy_hijack:hijacked(HI,H,Uri) of
        true ->
            %% TODO: avoid using http_pipe to send to piroxy_hijack because
            %% it does not need to be pipelined on the server-side end
            piroxy_hijack:connect(Req,HI);
        false ->
            request_manager:connect(Req, HI)
    end.

relay_head(H, HI, Uri, Bin, D) ->
    {_,Host,_} = HI,
    Req = request_manager:nextid(),
    ok = http_pipe:new(Req),
    connect_request(Req,HI,H,Uri),
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
            D2 = D#data{reader=pihttp_lib:body_reader(H#head.bodylen),
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

urimap_hostinfo(#{scheme:=Scheme,host:=Host,port:=Port}) ->
    if
        Scheme /= <<"http">>, Scheme /= <<"https">> ->
            exit(badarg);
        true ->
            {binary_to_atom(Scheme, latin),Host,Port}
    end;

urimap_hostinfo(#{scheme:=<<"http">>,host:=Host}) ->
    {http,Host,80};

urimap_hostinfo(#{scheme:=<<"https">>,host:=Host}) ->
    {https,Host,443}.

%% Modify the status line in the header so that it is a relative version of itself.
%% This amounts to removing the explicit reference to a hostname.
relativize(H,#{path:=Path0} = M) ->
    MethodBin = pihttp_lib:method_bin(H#head.method),
    Query = case M of
                #{query:=Q} -> Q;
                _ -> []
            end,
    Path = iolist_to_binary([Path0|Query]),
    Line = <<MethodBin/binary," ",Path/binary," ", ?HTTP11>>,
    %%M1 = lists:foldl(fun (X,M) -> maps:remove(X,M) end,M0,[host,port]),
    {ok,H#head{line=Line}}.

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
