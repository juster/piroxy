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
    case phttp:nsplit(3, H#head.line, <<" ">>) of
        {error,badarg} ->
            http_pipe:recvall(Id, [{status,http_bad_request}]);
        {ok,[_Get,RelUri,<<"HTTP/1.1">>]} ->
            io:format("*DBG* RelUri=~p~n", [RelUri]),
            get_uri(Id, RelUri, H, S);
        {ok,[_,_,Ver]} ->
            ?LOG_WARNING("piroxy_embed: bad http version ~s", [Ver]),
            http_pipe:recvall(Id, [{status,http_bad_request}])
    end,
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

get_uri(Id, <<"/">>, _H, _S) ->
    Bin = <<"<!DOCTYPE html><html><head><title>Index</title>
<meta charset='utf-8'>
</head>
<body>
<h1>Index</h1>
<script type='text/javascript'>
(function(){
var ws = new WebSocket('wss://piroxy/ws')
ws.binaryType = 'blob'
ws.onopen = function(evt){
    console.log('*DBG* WS opened!')
}
ws.onclose = function(evt){
    console.log('*DBG* WS closed!')
}
ws.onerror = function(evt){
    console.log('*DBG* WS error:', evt.toString())
}
ws.onmessage = function(evt){
    console.log('*DBG* WS message:', evt)
}
})()
</script>
            </body></html>">>,
    reply_static(Id, "text/html", Bin);

get_uri(Id, <<"/ws">>, H, _S) ->
    case fieldlist:get_value(<<"sec-websocket-key">>, H#head.headers) of
        not_found ->
            io:format("*DBG* missing sec-websocket-key!~n"),
            http_pipe:recvall(Id, [{status,http_bad_request}]);
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
            http_pipe:recvall(Id, [Head,{upgrade_socket,Start}])
    end;

get_uri(Id, _, _, _S) ->
    http_pipe:recvall(Id, [{status,http_not_found}]).

reply_static(Id, ContentType, Bin) ->
    Len = byte_size(Bin),
    L = [{"content-type", ContentType},
         {"content-length", integer_to_list(Len)}],
    Headers = fieldlist:from_proplist(L),
    Head = #head{line = <<"HTTP/1.1 200 OK">>,
                 headers = Headers,
                 bodylen = Len},
    http_pipe:recvall(Id, [Head, {body,Bin}]).

reply_error(Id, HttpErr) ->
    Len = length(HttpErr),
    L = [{"content-type", "text/plain"},
         {"content-length", integer_to_list(Len)}],
    Headers = fieldlist:from_proplist(L),
    Head = #head{line = <<"HTTP/1.1 200 OK">>,
                 headers = Headers,
                 bodylen = Len},
    http_pipe:recvall(Id, [Head, {body,HttpErr}]).
