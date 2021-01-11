-module(piroxy_hijack).
-behavior(gen_server).
-import(lists, [filtermap/2, foreach/2, reverse/1]).
-include_lib("kernel/include/logger.hrl").
-include("../include/phttp.hrl").

-define(HJ_RAND_SZ, 16).
-define(HJ_TARGET, {https,<<"piroxy">>,_}).
-define(HJ_CLEANUP_MS, 60000).
-record(state, {pipes=gb_trees:empty(), replays=gb_trees:empty()}).
-export([hijacked/2, connect/2, start_link/1, cleanup_replay/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

hijacked(Target, Head) ->
    gen_server:call(?MODULE, {hijacked,Target,Head}).

connect(Id, Target) ->
    gen_server:cast(?MODULE, {connect,Id,Target}).

cleanup_replay(Key) ->
    gen_server:cast(?MODULE, {cleanup_replay,Key}).

start_link(Opts) ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], Opts).

init([]) ->
    {ok,#state{}}.

handle_call({hijacked, ?HJ_TARGET, _}, _From, S) ->
    {reply, true, S};

%% checks every GET request to see if it was previously stored as a replay
handle_call({hijacked, Target, #head{method=get}=H}, _From, S) ->
    case head_reluri(H) of
        {ok,RelUri} ->
            %%io:format("*DBG* DONG: ~p~n", [{Target,RelUri}]),
            Bool = gb_trees:is_defined({Target,RelUri}, S#state.replays),
            {reply,Bool,S};
        {error,_} ->
            io:format("*DBG* DANG: ~p~n", [{Target}]),
            {reply,false,S}
    end;

handle_call({hijacked,_,_}, _From, S) ->
    {reply,false,S}.

handle_cast({connect,Id,Target}, S) ->
    http_pipe:listen(Id, self()),
    Tree = gb_trees:insert(Id, Target, S#state.pipes),
    {noreply,S#state{pipes=Tree}};

handle_cast({cleanup_replay,Key}, S) ->
    io:format("*DBG* cleanup_replay: ~p~n", [Key]),
    case gb_trees:take_any(Key, S#state.replays) of
        error ->
            {noreply,S};
        {{TRef,_},Tree} ->
            _ = timer:cancel(TRef), % the timer probably called us but sanity check
            {noreply, S#state{replays=Tree}}
    end.

handle_info({http_pipe,Id,#head{method=get}=H}, S0) ->
    {L,S1} = case head_reluri(H) of
                 {error,badarg} ->
                     [{status,http_bad_request}];
                 {ok,RelUri} ->
                     Target = gb_trees:get(Id, S0#state.pipes),
                     io:format("*DBG* FTW: ~p~n", [Target]),
                     get_uri(Target, RelUri, Id, H, S0)
             end,
    http_pipe:recvall(Id, L),
    Tree = gb_trees:delete(Id, S1#state.pipes),
    {noreply, S1#state{pipes=Tree}};

handle_info({http_pipe,Id,#head{method=M}}, S)
  when M /= get ->
    http_pipe:recvall(Id, [{status,http_method_not_supported}]),
    Tree = gb_trees:delete(Id, S#state.pipes),
    {noreply,S#state{pipes=Tree}};

handle_info({http_pipe,_Id,A}, S)
  when A == eof; A == cancel ->
    {noreply,S};

handle_info({http_pipe,_,Any}, _S) ->
    {stop,{unexpected_message,Any}}.

get_uri(?HJ_TARGET, <<"/">>, _Id, H, S) ->
    {static_file(<<"index.html">>, H), S};

get_uri(?HJ_TARGET, <<"/ws">>, Id, H, S) ->
    case fieldlist:get_value(<<"sec-websocket-key">>, H#head.headers) of
        not_found ->
            io:format("*DBG* missing sec-websocket-key!~n"),
            {[{status,http_bad_request}],S};
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
            {[Head,{upgrade_socket,Start}],S}
    end;

get_uri(?HJ_TARGET, <<"/cp/",BinId/binary>>, _Id, _H, S) ->
    case re:run(BinId, "^([0-9]+)([.][0-9]+)*$", [{capture,none}]) of
        match ->
            %% TODO: implement dotted Id numbers
            ConnId = binary_to_integer(BinId),
            io:format("*DBG* DING!~n"),
            case piroxy_ram_log:target(ConnId) of
                not_found ->
                    {[{status,http_not_found}], S};
                Target ->
                    {Uri, S1} = store_replay(Target, ConnId, S),
                    {redirect(Uri), S1}
            end;
        nomatch ->
            {[{status,http_not_found}], S}
    end;

get_uri(Target, Path, _Id, H, S) ->
    case lookup_replay(Target, Path, S) of
        {found,L} ->
            {L, S};
        not_found ->
            {static_file(Path,H), S}
    end.

lookup_replay(Target, Path, S) ->
    case gb_trees:lookup({Target,Path}, S#state.replays) of
        {value, {_,OrigId}} ->
            cleanup_replay({Target,Path}),
            {found,replay(OrigId)};
        none ->
            not_found
    end.

store_replay(Target, OrigId, S) ->
    Path = rand_path(),
    Key = {Target,Path},
    {ok,TRef} = timer:apply_after(?HJ_CLEANUP_MS, ?MODULE, cleanup_replay, [Key]),
    Tree = gb_trees:insert(Key, {TRef,OrigId}, S#state.replays),
    io:format("*DBG* Tree=~p~n", gb_trees:to_list(Tree)),
    {rebuild_uri(Key), S#state{replays=Tree}}.

rebuild_uri({{http,Host,80}, RelPath}) -> <<"http://",Host/binary,RelPath/binary>>;
rebuild_uri({{https,Host,443}, RelPath}) -> <<"https://",Host/binary,RelPath/binary>>;
rebuild_uri({{Proto,Host,Port}, RelPath}) ->
    <<(atom_to_binary(Proto))/binary,"://",
      Host/binary,(integer_to_binary(Port))/binary,
      RelPath/binary>>.

rand_path() ->
    Bin1 = crypto:strong_rand_bytes(?HJ_RAND_SZ),
    Bin2 = lists:foldl(fun ({A,B}, B64) ->
                               binary:replace(B64, A, B, [global])
                       end,
                       base64:encode(Bin1),
                       [{<<"+">>,<<"-">>}, {<<"/">>,<<"_">>}, {<<"=">>,<<>>}]),
    <<"/",Bin2/binary>>.

static_file(File, H) ->
    case {illegal_filename(File), revind($., File)} of
        {A,B} when A == true; B == nomatch ->
            [{status,http_not_found}];
        {false,I} ->
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

redirect(Uri) ->
    Content = <<"Redirecting to ",Uri/binary>>,
    Headers = [{"location",Uri},
               {"content-type","text/plain"},
               {"content-length",integer_to_list(byte_size(Content))}],
    [#head{line = <<"HTTP/1.1 302 Redirect">>,
           headers = fieldlist:from_proplist(Headers),
           bodylen = byte_size(Content)}, {body,Content}].

illegal_filename(File) ->
    case binary:match(File, [<<"/">>, <<"\\">>, <<"..">>, <<0>>]) of
        nomatch -> false;
        _ -> true
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

replay(OldId) ->
    io:format("*DBG* replay(~p)~n", [OldId]),
    case piroxy_ram_log:log(OldId, recv) of
        [] ->
            [{status, http_not_found}];
        L1 ->
            L2 = [element(5,T) || T <- L1],
            %%io:format("*DBG* replay events:~n~p~n", [L2]),
            expand_body(L2)
    end.

expand_body(L) ->
    expand_body(L, []).

expand_body([], L2) ->
    reverse(L2);
expand_body([{body,Digest,_}|_]=L1, L2) ->
    %% lookup the body on the first {body,_} term we find
    case piroxy_ram_log:body(Digest) of
        not_found ->
            error({missing_body,Digest});
        IoList ->
            expand_body(L1, L2, 0, iolist_to_binary(IoList))
    end;

expand_body([X|L1], L2) ->
    expand_body(L1, [X|L2]).

expand_body([{body,_Digest,Size}|L1], L2, Pos, Bin) ->
    Chunk = binary_part(Bin, Pos, Size),
    expand_body(L1, [{body,Chunk}|L2], Pos+Size, Bin);

expand_body([X|L1], L2, Pos, Bin) ->
    expand_body(L1, [X|L2], Pos, Bin).

head_reluri(H) ->
    case phttp:nsplit(3, H#head.line, <<" ">>) of
        {error,_} = Err ->
            Err;
        {ok,[_Method,RelUri,<<"HTTP/1.1">>]} ->
            {ok,RelUri};
        {ok,_} ->
            {error,badarg}
    end.


