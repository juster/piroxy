-module(http11_req).
-include("../include/phttp.hrl").

-export([new/0, read/2, encode/1]).
-export([body_length/3, head/2, body/2, reset/1]). % callbacks

%%%
%%% EXTERNAL INTERFACE
%%% (called by piserver proc)

%%% Callback state: {RequestCounter,DefaultHostInfo,ServerPid}
new() ->
    http11_statem:start_link(?MODULE, {0,null,self()}).

read(Pid, Bin) ->
    http11_statem:read(Pid, Bin).

encode(Bin) ->
    http11_statem:encode(Bin).

%%%
%%% CALLBACKS
%%% (called by http11_statem proc)

body_length(StatusLn, Headers, State) ->
    {ok,[MethodBin,_UriBin,VerBin]} = phttp:nsplit(3, StatusLn, <<" ">>),
    case phttp:version_atom(VerBin) of
        http11 ->
            ok;
        Ver ->
            exit({unknown_version,Ver})
    end,
    case phttp:method_atom(MethodBin) of
        unknown ->
            exit({unknown_method,MethodBin});
        Method ->
            case request_length(Method, Headers) of
                {error,Rsn} -> exit(Rsn);
                {ok,BodyLen} -> {BodyLen,State}
            end
    end.

request_length(connect, _) -> {ok,0};
request_length(get, _) -> {ok,0};
request_length(options, _) -> {ok,0};
request_length(_, Headers) -> pimsg:body_length(Headers).

head(H, State0) ->
    {Req,State} = nextreq(State0),
    case target(H) of
        {tunnel,HI} ->
            %% Connect uses the "authority" form of URIs and so
            %% cannot be used with relativize/2.
            pievents:make_request(Req, HI, H),
            setelement(2,State,HI);
        relative ->
            %% HTTP header is for a relative URL. Hopefully this is inside of a
            %% CONNECT tunnel!
            case element(2,State0) of
                null ->
                    exit(host_missing);
                HI ->
                    pievents:make_request(Req, HI, H),
                    State
            end;
        {absolute,HI} ->
            pievents:make_request(Req, HI, relativize(H)),
            State
    end.

body(Bin, State) ->
    pievents:stream_request(lastreq(State), Bin),
    State.

reset(State) ->
    pievents:end_request(lastreq(State)),
    State.

%%%
%%% INTERNAL FUNCTIONS
%%%

lastreq({I,_,Pid}) ->
    {Pid,I}.

nextreq({I,HI,Pid}) ->
    J = I+1,
    Req = {Pid,J},
    {Req, {J,HI,Pid}}.

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
        {error,_} = Err -> Err;
        {ok,{_Scheme,_UserInfo,Host,_Port,Path0,Query}} ->
            case check_host(Host, H#head.headers) of
                {error,_} = Err -> Err;
                ok ->
                    MethodBin = phttp:method_bin(H#head.method),
                    Path = iolist_to_binary([Path0|Query]),
                    Line = <<MethodBin/binary, " ", Path/binary, " ", ?HTTP11>>,
                    {ok,H#head{line=Line}}
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
