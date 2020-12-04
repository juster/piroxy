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
    gen_server:start({local,?MODULE}, ?MODULE, [], Opts).

init([]) ->
    {ok,#state{}}.

handle_call(_, _, S) ->
    {reply,ok,S}.

handle_cast({connect,Id}, S) ->
    ok = http_pipe:listen(Id, self()),
    {noreply,S}.

handle_info({http_pipe,Id,#head{method=get}=H}, S) ->
    case phttp:nsplit(3, H#head.line, <<" ">>) of
        {error,badarg} ->
            http_pipe:recv(Id, {error,http_invalid_request}),
            http_pipe:recv(Id, eof);
        {ok,[_Get,RelUri,<<"HTTP/1.1">>]} ->
            get_uri(Id, RelUri, S);
        {ok,[_,_,Ver]} ->
            ?LOG_WARNING("piroxy_embed: bad http version ~s", [Ver]),
            http_pipe:recv(Id, {error,http_invalid_request}),
            http_pipe:recv(Id, eof)
    end,
    {noreply,S};

handle_info({http_pipe,Id,#head{method=M}}, S)
  when M /= get ->
    http_pipe:recv(Id, {error,http_method_not_supported}),
    http_pipe:recv(Id, eof),
    {noreply,S};

handle_info({http_pipe,_Id,eof}, S) ->
    {noreply,S};

handle_info({http_pipe,_,Any}, _S) ->
    {stop,{unexpected_message,Any}}.

get_uri(Id, <<"/">>, _S) ->
    Bin = <<"<!DOCTYPE html><html><head><title>Index</title></head>",
            "<body><h1>Index</h1></body></html>">>,
    reply_static(Id, "text/html", Bin);

get_uri(Id, _, _S) ->
    reply_error(Id, "404 Not Found").

reply_static(Id, ContentType, Bin) ->
    Len = byte_size(Bin),
    L = [{"content-type", ContentType},
         {"content-length", integer_to_list(Len)}],
    Headers = fieldlist:from_proplist(L),
    http_pipe:recv(Id, #head{line = <<"HTTP/1.1 200 OK">>,
                             headers = Headers,
                             bodylen = Len}),
    http_pipe:recv(Id, {body,Bin}),
    http_pipe:recv(Id, eof).

reply_error(Id, HttpErr) ->
    Len = length(HttpErr),
    L = [{"content-type", "text/plain"},
         {"content-length", integer_to_list(Len)}],
    Headers = fieldlist:from_proplist(L),
    http_pipe:recv(Id, #head{line = <<"HTTP/1.1 200 OK">>,
                             headers = Headers,
                             bodylen = Len}),
    http_pipe:recv(Id, {body,HttpErr}),
    http_pipe:recv(Id, eof).
