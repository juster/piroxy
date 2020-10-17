-module(http11_req).
-include("../include/phttp.hrl").

-export([init/1, head/3, body/2, reset/1]).

%%%
%%% INTERFACE CALLBACKS
%%%

init([]) ->
    %% State is {HostName,Counter} where HostName is a previously specified
    %% target hostname (via CONNECT) and Counter is an increasing integer which
    %% is used to generate request identifiers.
    {ok,{null,0}}.

head(State0, StatusLn, Headers) ->
    case request_head(StatusLn, Headers) of
        {error,_} = Err1 ->
            ?DBG("head", {err1,Err1}),
            Err1;
        {ok,H1} ->
            case request_target(H1) of
                {error,_} = Err2 ->
                    ?DBG("head", {err2,Err2}),
                    Err2;
                {tunnel,HostInfo,_Uri} ->
                    %% Connect uses the "authority" form of URIs and so
                    %% cannot be used with relativize/2.
                    {ReqId,State} = nextid(State0),
                    pievents:make_request(ReqId, HostInfo, H1),
                    {ok, H1, setelement(1,State,HostInfo)};
                {direct,null,_RelUri} ->
                    %% HostInfo is null if a relative URL is provided by the
                    %% client. Hopefully this is inside of a CONNECT tunnel!
                    {ReqId, State} = nextid(State0),
                    pievents:make_request(ReqId, element(1,State), H1),
                    {ok, H1, State};
                {direct,HostInfo,Uri} ->
                    case relativize(Uri, H1) of
                        {error,_} = Err3 ->
                            ?DBG("head", {err3,Err3}),
                            Err3;
                        {ok,H2} ->
                            {ReqId,State} = nextid(State0),
                            pievents:make_request(ReqId, HostInfo, H2),
                            {ok,H2,State}
                    end
            end
    end.

body({_,I}, Bin) ->
    pievents:stream_request({self(),I}, Bin),
    ok.

reset({_,I} = State) ->
    %%inbound_stream:finish_request(Pid),
    pievents:end_request({self(),I}),
    {ok,State}.

%%%
%%% INTERNAL FUNCTIONS
%%%

nextid({H,I}) ->
    {{self(),I+1}, {H,I+1}}.

request_head(StatusLn, Headers) ->
    {ok,[MethodBin,_UriBin,VerBin]} = phttp:nsplit(3, StatusLn, <<" ">>),
    case {phttp:method_atom(MethodBin), phttp:version_atom(VerBin)} of
        {unknown,_} ->
            ?DBG("head", {unknown_method,MethodBin}),
            {error,{unknown_method,MethodBin}};
        {_,unknown} ->
            ?DBG("head", {unknown_version,VerBin}),
            {error,{unknown_version,VerBin}};
        {Method,Ver} ->
            case request_length(Method, Headers) of
                {error,_} = Err -> Err;
                {ok,BodyLen} ->
                    {ok,#head{line=StatusLn, method=Method, version=Ver,
                              headers=Headers, bodylen=BodyLen}}
            end
    end.

request_length(connect, _) -> {ok,0};
request_length(get, _) -> {ok,0};
request_length(options, _) -> {ok,0};
request_length(_, Headers) -> pimsg:body_length(Headers).

%% Returns HostInfo ({Host,Port}) for the provided request HTTP message header.
%% If the Head contains a request to a relative URI, Host=null.
request_target(Head) ->
    %% XXX: splits the request line twice (in request_head as well)
    {ok,[_,UriBin,_]} = phttp:nsplit(3, Head#head.line, <<" ">>),
    case {Head#head.method, UriBin} of
        {connect,_} ->
            {ok,[Host,Port]} = phttp:nsplit(2, UriBin, <<":">>),
            case Port of
                <<"443">> ->
                    {tunnel, {https,Host,binary_to_integer(Port)}, UriBin};
                <<"80">> ->
                    {tunnel, {http,Host,binary_to_integer(Port)}, UriBin};
                _ ->
                    {error,http_bad_request}
            end;
        {_,<<"*">>} ->
            {direct,null,UriBin};
        {_,<<"/",_/binary>>} ->
            %% relative URI, hopefully we are already CONNECT-ed to a
            %% single host
            {direct,null,UriBin};
        _ ->
            case http_uri:parse(UriBin) of
                {error,{malformed_uri,_,_}} ->
                    {error, http_bad_request};
                {ok,{Scheme,_UserInfo,Host,Port,_Path0,_Query}} ->
                    %% XXX: never Fragment?
                    %% XXX: how to use UserInfo?
                    %% URI should be absolute when received from proxy client!
                    %% Convert to relative before sending to host.
                    {direct,{Scheme,Host,Port},UriBin}
            end
    end.

relativize(Uri, H) ->
    case http_uri:parse(Uri) of
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
