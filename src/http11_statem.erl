-module(http11_statem).
-behavior(gen_statem).
-include("../include/phttp.hrl").

-export([start_link/2, read/2, encode/1]).
-export([init/1, callback_mode/0, handle_event/4]).
-export([head/3, body/3]).

%%%
%%% EXTERNAL INTERFACE
%%%

start_link(M, A) ->
    gen_statem:start_link(?MODULE, [M, A], []).

read(Pid, Bin) ->
    gen_statem:cast(Pid, Bin).

encode(#head{line=Line, headers=Headers}) ->
    [Line,<<?CRLF>>,fieldlist:to_binary(Headers)|<<?CRLF>>];

encode({body,Body}) ->
    Body;

encode({error,Reason}) ->
    [error_statusln(Reason)|<<?CRLF>>];

encode({status,HttpStatus}) ->
    case phttp:status_bin(HttpStatus) of
        {ok,Bin} ->
            [<<?HTTP11>>," ",Bin,<<?CRLF>>|<<?CRLF>>];
        not_found ->
            exit(badarg)
    end.

%%%
%%% BEHAVIOR CALLBACKS
%%%

callback_mode() -> [state_functions].

init([M,A]) ->
    {ok, head, {pimsg:head_reader(),M,A}}.

head(cast, empty, State) ->
    {keep_state,State};

head(cast, Bin, {Reader0,M,A0}) ->
    case pimsg:head_reader(Reader0, Bin) of
        {error,Reason} ->
            exit(Reason);
        {continue,Reader} ->
            {keep_state,{Reader,M,A0}};
        {done,StatusLine,Headers,Rest} ->
            {Len,A1} = M:body_length(StatusLine, Headers, A0),
            Head = head_record(StatusLine, Headers, Len),
            A2 = M:head(Head, A1),
            Reader = pimsg:body_reader(Len),
            {next_state,body,{Reader,M,A2},
             {next_event,cast,Rest}}
    end.

body(cast, empty, State) ->
    {keep_state,State};

body(cast, Bin1, {Reader0,M,A0}) ->
    case pimsg:body_reader(Reader0, Bin1) of
        {error,Reason} ->
            exit(Reason);
        {continue,empty,Reader} ->
            {keep_state,{Reader,M,A0}};
        {continue,Bin2,Reader} ->
            A = M:body(Bin2, A0),
            {keep_state,{Reader,M,A}};
        {done,Bin2,Rest} ->
            A1 = case Bin2 of
                     empty -> A0;
                     _ -> M:body(Bin2,A0)
                 end,
            A2 = M:reset(A1),
            {next_state,head,{pimsg:head_reader(),M,A2},
             {next_event,cast,Rest}}
    end.

handle_event(_,_,_,_) ->
    keepstate_and_data.

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

%%%
%%% INTERNAL FUNCTIONS
%%%

error_statusln(host_mismatch) -> error_statusln(http_bad_request);
error_statusln(host_missing) -> error_statusln(http_bad_request);
error_statusln({malformed_uri,_,_}) -> error_statusln(http_bad_request);
error_statusln({unknown_method,_}) -> error_statusln(http_bad_request);
error_statusln({unknown_version,_}) -> error_statusln(http_bad_request);
error_statusln({unknown_length,_,_}) -> error_statusln(http_bad_request);

%% from pimsg:body_length/1
error_statusln({missing_length,_}) -> error_statusln(http_bad_request);

error_statusln(Reason) ->
    case phttp:status_bin(Reason) of
        {ok,Bin} -> Bin;
        not_found ->
            {ok,Bin} = phttp:status_bin(http_bad_gateway),
            [<<?HTTP11>>," ",Bin|<<?CRLF>>]
    end.

