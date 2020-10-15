-module(http11_req).
-include("../include/phttp.hrl").

-export([init/1, fail/2, head/3, body/2, reset/1]).

%%%
%%% INTERFACE CALLBACKS
%%%

init([Pid]) ->
    {ok,Pid}.

fail(Pid, Reason) ->
    inbound_stream:reflect(Pid, {error,Reason}),
    Reason.

head(Pid, StatusLn, Headers) ->
    case request_head(StatusLn, Headers) of
        {error,_} = Err1 -> Err1;
        {ok,H1} ->
            case {H1#head.method, request_target(H1)} of
                {_,{error,_}} = Err2 -> Err2;
                {options,{null,<<"*">>}} ->
                    inbound_stream:reflect(Pid, {status,http_ok});
                {_,{null,_RelUri}} ->
                    %% HostInfo is null if a relative URL is provided by the
                    %% client. Hopefully this is inside of a CONNECT tunnel!
                    {ok,_Ref} = inbound:new(Pid, null, H1),
                    {ok,H1};
                {connect,{HostInfo,_Uri}} ->
                    inbound_stream:force_host(Pid, HostInfo),
                    {tunnel,{http11_stream,[http11_req,[Pid]]}, HostInfo};
                {_,{HostInfo,Uri}} ->
                    case relativize(Uri, H1) of
                        {error,_} = Err -> Err;
                        {ok,H2} ->
                            {ok,_Ref} = inbound:new(Pid, HostInfo, H2),
                            {ok,H2}
                    end
            end
    end.

body(Pid, Bin) ->
    inbound_stream:stream_request(Pid, Bin).

reset(Pid) ->
    inbound_stream:finish_request(Pid),
    Pid.

%%%
%%% INTERNAL FUNCTIONS
%%%

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
request_length(_, Headers) -> body_length(Headers).

body_length(Headers) ->
    %%io:format("DBG body_length_by_headers: Headers=~p~n", [Headers]),
    TransferEncoding = fieldlist:get_value(<<"transfer-encoding">>,
                                           Headers, ?EMPTY),
    ContentLength = fieldlist:get_value(<<"content-length">>,
                                        Headers, ?EMPTY),
    case {ContentLength, TransferEncoding} of
        {?EMPTY, ?EMPTY} ->
            {error,{missing_length,Headers}};
        {?EMPTY, Bin} ->
            %% XXX: not precise, potentially buggy/insecure. needs a rewrite.
            %%io:format("*DBG* transfer-encoding: ~s~n", [Bin]),
            case binary:match(Bin, <<"chunked">>) of
                nomatch ->
                    {error,{missing_length,Headers}};
                _ ->
                    {ok, chunked}
            end;
        {Bin, _} ->
            {ok, binary_to_integer(Bin)}
    end.

%% Returns HostInfo ({Host,Port}) for the provided request HTTP message header.
%% If the Head contains a request to a relative URI, Host=null.
request_target(Head) ->
    %% XXX: splits the request line twice (in request_head as well)
    {ok,[_,UriBin,_]} = phttp:nsplit(3, Head#head.line, <<" ">>),
    case {Head#head.method, UriBin} of
        {connect,_} ->
            {ok,[Host,Port]} = phttp:nsplit(2, UriBin, <<":">>),
            case Port of
                <<"443">> -> {{https,Host,binary_to_integer(Port)},UriBin};
                <<"80">> -> {{http,Host,binary_to_integer(Port)},UriBin};
                _ -> {error,http_bad_request}
            end;
        {_,<<"*">>} ->
            {null,UriBin};
        {_,<<"/",_/binary>>} ->
            %% relative URI, hopefully we are already CONNECT-ed to a
            %% single host
            {null,UriBin};
        _ ->
            case http_uri:parse(UriBin) of
                {error,{malformed_uri,_,_}} ->
                    {error, http_bad_request};
                {ok,{Scheme,_UserInfo,Host,Port,_Path0,_Query}} ->
                    %% XXX: never Fragment?
                    %% XXX: how to use UserInfo?
                    %% URI should be absolute when received from proxy client!
                    %% Convert to relative before sending to host.
                    HostInfo = {Scheme,Host,Port},
                    {HostInfo,UriBin}
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
