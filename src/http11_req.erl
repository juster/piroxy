-module(http11_req).
-include("../include/phttp.hrl").

-export([start_link/1, stop/1, read/2, push/3, encode/1, shutdown/2]).
-export([head/3, body/2, reset/1]). % callbacks

%%%
%%% EXTERNAL INTERFACE
%%% (called by piserver proc)

%%% Callback state: {RequestCounter,DefaultHostInfo,ServerPid}
start_link([]) ->
    http11_statem:start_link(?MODULE, {0,null,self()},
                             {?REQUEST_TIMEOUT,infinity}, []).

stop(Pid) ->
    gen_statem:stop(Pid).

read(Pid, Bin) ->
    http11_statem:read(Pid, Bin).

push(_Pid, Sock, Term) ->
    case send(Sock, encode(Term)) of
        {error,Reason} ->
            exit(Reason);
        ok ->
            ok
    end.

encode(Bin) ->
    http11_statem:encode(Bin).

shutdown(Pid, Reason) ->
    http11_statem:shutdown(Pid, Reason).

%%%
%%% CALLBACKS
%%% (called by http11_statem proc)

head(StatusLn, Headers, State0) ->
    Len = body_length(StatusLn, Headers),
    H = head_record(StatusLn, Headers, Len),
    {Req,State} = nextreq(State0),
    case target(H) of
        {tunnel,HI} ->
            %% Connect uses the "authority" form of URIs and so
            %% cannot be used with relativize/2.
            make_request(Req, HI, H),
            {H,setelement(2,State,HI)};
        relative ->
            %% HTTP header is for a relative URL. Hopefully this is inside of a
            %% CONNECT tunnel!
            case element(2,State0) of
                null ->
                    exit(host_missing);
                HI ->
                    make_request(Req, HI, H),
                    {H,State}
            end;
        {absolute,HI} ->
            Hrel = relativize(H),
            make_request(Req, HI, Hrel),
            {Hrel,State}
    end.

body(Bin, State) ->
    morgue:append(lastreq(State), Bin),
    State.

reset(State) ->
    morgue:append(lastreq(State), done),
    State.

%%%
%%% INTERNAL FUNCTIONS
%%%

make_request(Req, <<"*">>=Target, #head{method=options}=H) ->
    pievents:make_request(Req, Target, H),
    pievents:respond(Req, {status,ok}),
    pievents:close_response(Req),
    ok;

make_request(Req, Target, #head{method=connect}=H) ->
    pievents:make_request(Req, Target, H),
    pievents:make_tunnel(Req, Target),
    ok;

make_request(Req, HI, H) ->
    pievents:make_request(Req, HI, H),
    request_manager:make_request(Req, HI, H).

send({tcp,Sock}, Bin) ->
    gen_tcp:send(Sock, Bin);

send({ssl,Sock}, Bin) ->
    ssl:send(Sock, Bin).

lastreq({I,_,Pid}) ->
    {Pid,I}.

nextreq({I,HI,Pid}) ->
    J = I+1,
    Req = {Pid,J},
    {Req, {J,HI,Pid}}.

head_record(StatusLn, Headers, BodyLen) ->
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
                  headers=Headers, bodylen=BodyLen}
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
                    {tunnel, {https,Host,binary_to_integer(Port)}};
                <<"80">> ->
                    %% NYI
                    {tunnel, {http,Host,binary_to_integer(Port)}};
                _ ->
                    exit(http_bad_request)
            end;
        {options,<<"*">>} ->
            proxy;
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
