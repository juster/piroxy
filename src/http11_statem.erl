-module(http11_statem).
-behavior(gen_statem).
-include("../include/phttp.hrl").

-export([start_link/2, read/2, encode/1, cb_state/1, cb_state/2]).
-export([init/1, callback_mode/0, handle_event/4]).

%%%
%%% EXTERNAL INTERFACE
%%%

start_link(M, A) ->
    gen_statem:start_link(?MODULE, [M, A], []).

read(Pid, Bin) ->
    gen_statem:cast(Pid, Bin).

cb_state(Pid) ->
    gen_statem:call(Pid, get_cb_state).

cb_state(Pid, Term) ->
    gen_statem:cast(Pid, {set_cb_state,Term}).

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

callback_mode() -> [handle_event_function].

init([M,A]) ->
    {ok, head, {pimsg:head_reader(),M,A}}.

handle_event(cast, empty, _, _) ->
    keep_state_and_data;

handle_event({call,From}, get_cb_state, _, {_,_,A}) ->
    {keep_state_and_data,{reply,From,A}};

handle_event(cast, {set_cb_state,A}, _, {R,M,_}) ->
    {keep_state,{R,M,A}};

handle_event(cast, Bin, head, {Reader0,M,A0}) ->
    case pimsg:head_reader(Reader0, Bin) of
        {error,Reason} ->
            exit(Reason);
        {continue,Reader} ->
            {keep_state,{Reader,M,A0}};
        {done,StatusLine,Headers,Rest} ->
            {H,A1} = M:head(StatusLine, Headers, A0),
            Reader = pimsg:body_reader(H#head.bodylen),
            {next_state,body,{Reader,M,A1},
             {next_event,cast,Rest}}
    end;

handle_event(cast, Bin1, body, {Reader0,M,A0}) ->
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
            case M:reset(A1) of
                shutdown ->
                    {stop, shutdown};
                A2 ->
                    {next_state,head,{pimsg:head_reader(),M,A2},
                     {next_event,cast,Rest}}
            end
    end;

handle_event(_,_,_,_) ->
    keep_state_and_data.

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

