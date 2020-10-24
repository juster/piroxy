-module(http11_statem).
-behavior(gen_statem).
-include("../include/phttp.hrl").

-export([start_link/3, stop/2, read/2, close/1, close/2, encode/1,
         replace_cb_state/2]).
-export([init/1, callback_mode/0, handle_event/4]).

%%%
%%% EXTERNAL INTERFACE
%%%

start_link(M, A, Opts) ->
    gen_statem:start_link(?MODULE, [M,A], Opts).

stop(Pid, Reason) ->
    gen_statem:stop(Pid, Reason, infinity).

read(Pid, Bin) ->
    gen_statem:cast(Pid, {data,Bin}).

replace_cb_state(Pid, Fun) ->
    gen_statem:cast(Pid, {replace_cb_state,Fun}).

close(Pid) ->
    close(Pid, normal).

close(Pid, Reason) ->
    gen_statem:cast(Pid, {close,Reason}).

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
    {ok, eof, {null,M,A}}.

handle_event(cast, empty, _, _) ->
    keep_state_and_data;

handle_event(cast, {replace_cb_state,Fun}, _, {R,M,A}) ->
    {keep_state,{R,M,Fun(A)}};

%% used to stop the process, without bypassing the messages in the queue
handle_event(cast, {close,Reason}, _, {_,M,A}) ->
    case erlang:function_exported(M, terminate, 2) of
        true ->
            M:terminate(Reason, A);
        false ->
            ok
    end,
    {stop, {shutdown,Reason}};

handle_event(cast, {data,<<>>}, eof, _) ->
    keep_state_and_data;

handle_event(cast, {data,empty}, _, _) ->
    keep_state_and_data;

handle_event(cast, {data,_}, eof, {_,M,A}) ->
    {next_state, head, {pimsg:head_reader(),M,A}, postpone};

handle_event(cast, {data,Bin}, head, {Reader0,M,A0}) ->
    case pimsg:head_reader(Reader0, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            {keep_state,{Reader,M,A0}};
        {done,StatusLine,Headers,Rest} ->
            {H,A} = M:head(StatusLine, Headers, A0),
            Reader = pimsg:body_reader(H#head.bodylen),
            {next_state,body,{Reader,M,A},
             {next_event,cast,{data,Rest}}}
    end;

handle_event(cast, {data,Bin1}, body, {Reader0,M,A0}) ->
    case pimsg:body_reader(Reader0, Bin1) of
        {error,Reason} ->
            {stop, Reason};
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
                connection_close ->
                    {stop, {shutdown,connection_close}};
                A2 ->
                    {next_state,eof,{null,M,A2},
                     {next_event,cast,{data,Rest}}}
            end
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

