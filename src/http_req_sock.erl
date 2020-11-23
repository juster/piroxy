%%% http_req_sock
%%% State machine.
%%% Receives HTTP requests from the socket as binary.
%%% Sends HTTP responses, received from 'http_pipe' as tuples.

-module(http_req_sock).
-behavior(gen_statem).
-import(lists, [reverse/1]).
-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-define(IDLE_TIMEOUT, 5*60*1000).
-define(ACTIVE_TIMEOUT, 5000).
%% TODO: move CONNECT_TIMEOUT here

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
    lists:foreach(fun ({X,_}) ->
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
    {next_state, head, D#data{reader=pimsg:head_reader()}, postpone};

handle_event(info, {A,_,Bin}, head, D)
  when A == tcp; A == ssl ->
    case pimsg:head_reader(D#data.reader, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            %% Keep the 'head' state but reset the timer.
            {keep_state,D#data{reader=Reader},
             {state_timeout,?ACTIVE_TIMEOUT,active}};
        {done,StatusLn,Headers,Rest} ->
            H = head(StatusLn, Headers),
            recv_head(H, target(H), Rest, D)
    end;

handle_event(info, {A,_,Bin1}, body, D)
  when A == tcp; A == ssl ->
    case pimsg:body_reader(D#data.reader, Bin1) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Bin2,Reader} ->
            %% Keep the 'body' state but reset the timer.
            case Bin2 of
                ?EMPTY -> ok;
                _ -> http_pipe:send(D#data.active, {body,Bin2})
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
handle_event(info, {A,_,Bin}, upgrade, D)
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

handle_event(info, {http_pipe,Res,eof}, upgrade, D) ->
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    case D#data.queue of
        [] ->
            error(request_underrun);
        [{Res,false}|Q] ->
            ?TRACE(Res, Host, "<", "EOF"),
            {keep_state, D#data{queue=Q}};
        [{Res,_UpState}] ->
            %% A successful upgrade will shutdown this statem before the eof
            %% message is received. If we get this far, an upgrade request did
            %% not result in a successful upgrade response (101). Restart the
            %% pipeline.
            ?TRACE(Res, Host, "<", "EOF"),
            Bin = iolist_to_binary(reverse(D#data.reader)),
            {next_state, idle,
             D#data{queue=[], reader=undefined, active=undefined},
             {next_event, info, {tcp,null,Bin}}}
    end;

handle_event(info, {http_pipe,Res,{upgrade,M,Args}}, upgrade, D) ->
    case D#data.queue of
        [] ->
            error(request_underrun);
        [{Res,false}|_] ->
            error(unexpected_upgrade);
        [{Res,Opts}] ->
            %% Transfers the socket to the new process and shuts down.
            M:start_client(D#data.socket, Args, Opts, reverse(D#data.reader)),
            {stop,shutdown};
        _ ->
            error(request_overrun)
    end;

handle_event(info, {http_pipe,Res,eof}, _, D) ->
    %% Avoid trying to encode the 'eof' atom. Pop the first response ID off the
    %% queue.
    [{Res,_}|Q] = D#data.queue,
    Host = case D#data.target of
               undefined -> "???";
               _ -> element(2,D#data.target)
           end,
    ?TRACE(Res, Host, "<", "EOF"),
    {keep_state, D#data{queue=Q}};

handle_event(info, {http_pipe,_,{upgrade,_,_}}, _, _) ->
    %% Ignore upgrade messages if we are not in the upgrade state.
    keep_state_and_data;

handle_event(info, {http_pipe,Res,#head{}=Head}, _, D) ->
    %% pipeline the next request ASAP
    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
    ?TRACE(Res, Host, "<", Head),
    send(D#data.socket, Head);

handle_event(info, {http_pipe,Res,Term}, _, D) ->
    case Term of
        {error,Rsn} ->
            {Res,_} = hd(D#data.queue),
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
            ?TRACE(0, Host, ">", started_tunnel),
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
    end.

%%%
%%% INTERNAL FUNCTIONS
%%%

send(Sock, Term) ->
    case pisock:send(Sock, phttp:encode(Term)) of
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
    {next_state, idle, D#data{reader=undefined},
     {next_event, info, {tcp,null,Bin}}};

recv_head(H, relative, Bin, D) ->
    %% HTTP header is for a relative URL. Hopefully this is inside of a
    %% CONNECT tunnel!
    HI = D#data.target,
    case HI of undefined -> exit(host_missing); _ -> ok end,
    relay_head(H, HI, Bin, D);

recv_head(H, {absolute,HI2}, Bin, D) ->
    %%case D#data.target of undefined -> ok; _ -> exit(host_connected) end,
    H2 = relativize(H),
    relay_head(H2, HI2, Bin, D).

relay_head(H, HI, Bin, D) ->
    {_,Host,_} = HI,
    Req = request_manager:nextid(),
    request_manager:connect(Req, http, HI),
    ok = http_pipe:new(Req),
    http_pipe:send(Req, H),
    ?TRACE(Req, Host, ">", H),
    UpState = upgrade_state(H),
    Q = D#data.queue ++ [{Req,UpState}],
    case {H#head.bodylen, UpState} of
        {0,false} ->
            %% Skip ahead to the idle state when we do not expect to receive
            %% any body data.
            ?TRACE(Req, Host, ">", "EOF"),
            http_pipe:send(Req, eof),
            D2 = D#data{reader=undefined, target=HI, queue=Q, active=undefined},
            {next_state,idle,D2,{next_event,info,{tcp,null,Bin}}};
        {_,false} ->
            D2 = D#data{reader=pimsg:body_reader(H#head.bodylen),
                        target=HI, queue=Q, active=Req},
            {next_state,body,D2,{next_event,info,{tcp,null,Bin}}};
        {0,_} ->
            %% An upgrade request stops the pipeline.
            %% Buffer any received binaries inside of reader.
            D2 = D#data{reader=[Bin], target=HI, queue=Q, active=Req},
            {next_state,upgrade,D2};
        {_,_} ->
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

upgrade_state(H) ->
    Headers = H#head.headers,
    Conn = fieldlist:has_value(<<"connection">>, <<"upgrade">>, Headers),
    Upgrade = fieldlist:get_value(<<"upgrade">>, H#head.headers),
    %%io:format("*DBG* Method=~s, Conn=~p, Upgrade=~s~n", [H#head.method, Conn, Upgrade]),
    case {H#head.method,Conn,Upgrade} of
        {_,_,not_found} ->
            false;
        {get,true,_} ->
            case fieldlist:get_value(<<"sec-websocket-key">>, Headers) of
                not_found ->
                    unknown;
                Key ->
                    {websocket,Key}
            end;
        _ ->
            false
    end.

