-module(piroxy_hijack).
-behavior(gen_server).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-record(state, {reqs=dict:new()}).
-export([target/1, connect/1, start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

target({http,<<"piroxy">>,80}) -> true;
target({https,<<"piroxy">>,443}) -> true;
target(_) -> false.

connect(Id) ->
    gen_server:cast(?MODULE, {connect,Id}).

start_link(Opts) ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], Opts).

init([]) ->
    {ok,#state{}}.

handle_call(_, _, S) ->
    {reply,ok,S}.

handle_cast({connect,Id}, S) ->
    http_pipe:listen(Id, self()),
    {noreply,S}.

handle_info({http_pipe,Id,#head{method=get}=H}, S) ->
    L = case phttp:nsplit(3, H#head.line, <<" ">>) of
            {error,badarg} ->
                [{status,http_bad_request}];
            {ok,[_Get,RelUri,<<"HTTP/1.1">>]} ->
                io:format("*DBG* RelUri=~p~n", [RelUri]),
                get_uri(RelUri, Id, H, S);
            {ok,[_,_,Ver]} ->
                ?LOG_WARNING("piroxy_embed: bad http version ~s", [Ver]),
                [{status,http_bad_request}]
        end,
    http_pipe:recvall(Id, L),
    {noreply,S};

handle_info({http_pipe,Id,#head{method=M}}, S)
  when M /= get ->
    http_pipe:recvall(Id, [{status,http_method_not_supported}]),
    {noreply,S};

handle_info({http_pipe,_Id,A}, S)
  when A == eof; A == cancel ->
    {noreply,S};

handle_info({http_pipe,_,Any}, _S) ->
    {stop,{unexpected_message,Any}}.

get_uri(<<"/">>, _Id, H, _S) ->
    static_file(<<"index.html">>, H);

get_uri(<<"/ws">>, Id, H, _S) ->
    case fieldlist:get_value(<<"sec-websocket-key">>, H#head.headers) of
        not_found ->
            io:format("*DBG* missing sec-websocket-key!~n"),
            [{status,http_bad_request}];
        Key ->
            io:format("*DBG* Sec-WebSocket-Key: ~s~n", [Key]),
            L = [
                 {"Sec-WebSocket-Version", "13"}, % TODO: match w/ client's
                 {"Sec-WebSocket-Accept", piroxy_hijack_ws:accept(Key)},
                 {"Upgrade", "websocket"},
                 {"Connection", "Upgrade"}
                ],
            Headers = fieldlist:from_proplist(L),
            {ok,Pid} = piroxy_hijack_ws:start(),
            Handshake = {piroxy_hijack_ws, handshake, [Pid]},
            Start = {ws_sock,start,[client,{handshake,Handshake},{id,Id}]},
            Head = #head{line = <<"HTTP/1.1 101 Switching Protocols">>,
                         headers = Headers,
                         bodylen = 0},
            [Head,{upgrade_socket,Start}]
    end;

get_uri(<<"/",Path/binary>>, _Id, H, _S) ->
    static_file(Path, H);

get_uri(_, _, _, _) ->
    [{status,http_not_found}].

static_file(File, H) ->
    case {binary:match(File, [<<"/">>, <<"\\">>, <<0>>]), revind($., File)} of
        {_,nomatch} ->
            [{status,http_not_found}];
        {nomatch,I} ->
            AppDir = code:lib_dir(piroxy),
            Path = filename:join([AppDir, "priv", "www", binary_to_list(File)]),
            io:format("*DBG* Path=~p~n", [Path]),
            case file:read_file(Path) of
                {error,enoent} ->
                    [{status,http_not_found}];
                {ok,Bin} ->
                    Ext = binary_part(File, I, byte_size(File)-I),
                    Headers = [{"content-type", extmime(Ext)},
                               {"content-length", integer_to_list(byte_size(Bin))}],
                    Head = #head{line = <<"HTTP/1.1 200 OK">>,
                                 method = H#head.method,
                                 headers = fieldlist:from_proplist(Headers),
                                 bodylen = byte_size(Bin)},
                    [Head, {body,Bin}]
            end
    end.

extmime(<<".txt">>) -> "text/plain";
extmime(<<".js">>) -> "text/javascript";
extmime(<<".html">>) -> "text/html";
extmime(_) -> "application/octect-stream".

%% Reverse index-of
revind(X, Bin) -> revind(X, Bin, byte_size(Bin)-1).
revind(_, _, I) when I < 0 -> nomatch;
revind(X, Bin, I) ->
    case binary:at(Bin, I) of X -> I; _ -> revind(X, Bin, I-1) end.

resp_static(_Id, ContentType, Bin) ->
    Len = byte_size(Bin),
    L = [{"content-type", ContentType},
         {"content-length", integer_to_list(Len)}],
    Headers = fieldlist:from_proplist(L),
    Head = #head{line = <<"HTTP/1.1 200 OK">>,
                 headers = Headers,
                 bodylen = Len},
    [Head, {body,Bin}].
