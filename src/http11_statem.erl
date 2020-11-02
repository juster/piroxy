-module(http11_statem).
-behavior(gen_statem).
-include("../include/phttp.hrl").

-export([start_link/3, start_link/4, read/2, swap_state/2, activate/1,
         shutdown/2, encode/1]).
-export([init/1, callback_mode/0, handle_event/4]).

%%%
%%% EXTERNAL INTERFACE
%%%

start_link(M, A, Opts) ->
    start_link(M, A, {infinity,infinity}, Opts).

%% Arguments:
%% 1. Callback module
%% 2. Callback extra args (state)
%% 3. Timeouts: {active timeout, idle timeout}
%% 4. gen_statem options
start_link(M, A, {_,_}=Timeouts, Opts) ->
    gen_statem:start_link(?MODULE, [M,A,Timeouts], Opts).

read(Pid, Bin) ->
    gen_statem:cast(Pid, {data,Bin}).

swap_state(Pid, Fun) ->
    gen_statem:cast(Pid, {swap_state,Fun}).

activate(Pid) ->
    gen_statem:cast(Pid, start_active_timer).

shutdown(Pid, Reason) ->
    gen_statem:cast(Pid, {shutdown,Reason}).

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

callback_mode() -> [handle_event_function, state_enter].

init([M,A,Ts]) ->
    {ok, eof, {null,M,A,Ts}}.

%% use enter events to choose between the idle timeout and active timeout
handle_event(enter, _, eof, {_,_,_,{_,T2}}) ->
    {keep_state_and_data,
     [{{timeout,idle},T2,[]},
      {{timeout,active},cancel}]};

handle_event(enter, _, _, {_,_,_,{T1,_}}) ->
    {keep_state_and_data,
     [{{timeout,idle},cancel},
      {{timeout,active},T1,[]}]};

%% switch to the active timeout when http11_res sends data and expects a result
handle_event(cast, start_active_timer, _, {_,_,_,{T1,_}}) ->
    {keep_state_and_data,
     [{{timeout,idle},cancel},
      {{timeout,active},T1,[]}]};

%% used by callback modules to replace their own state
handle_event(cast, {swap_state,Fun}, _, {R,M,A,Ts}) ->
    try
        {keep_state,{R,M,Fun(A),Ts}}
    catch
        _:Reason ->
            shutdown(self, Reason),
            keep_state_and_data
    end;

%% used to stop the process, without bypassing the messages in the queue
handle_event(cast, {shutdown,Reason}, _, {_,M,A,_}) ->
    case erlang:function_exported(M, terminate, 2) of
        true ->
            M:terminate(Reason, A);
        false ->
            ok
    end,
    {stop, {shutdown,Reason}};

handle_event({timeout,idle}, _, _, _) ->
    %% use the idle timeout to automatically close
    {stop, {shutdown,closed}};

handle_event({timeout,active}, _, _, _) ->
    {stop, {shutdown,timeout}};

handle_event(cast, {data,<<>>}, _, _) ->
    keep_state_and_data;

handle_event(cast, {data,empty}, _, _) ->
    keep_state_and_data;

handle_event(cast, {data,_}, eof, {_,M,A,Ts}) ->
    {next_state, head,
     {pimsg:head_reader(),M,A,Ts},
     postpone};

handle_event(cast, {data,Bin}, head, {Reader0,M,A0,Ts}) ->
    case pimsg:head_reader(Reader0, Bin) of
        {error,Reason} ->
            {stop,Reason};
        {continue,Reader} ->
            {keep_state,{Reader,M,A0,Ts}};
        {done,StatusLine,Headers,Rest} ->
            try
                {H,A1} = M:head(StatusLine, Headers, A0),
                case H#head.bodylen of
                    0 ->
                        A2 = M:reset(A1),
                        {next_state,eof,
                         {null,M,A2,Ts},
                         {next_event,cast,{data,Rest}}};
                    _ ->
                        Reader = pimsg:body_reader(H#head.bodylen),
                        {next_state,body,
                         {Reader,M,A1,Ts},
                         {next_event,cast,{data,Rest}}}
                end
            catch
                %% Make sure we do not lose the "Rest" remainder bytes.
                exit:{shutdown,{upgrade,Proto,Args}} ->
                    exit({shutdown,{upgrade,Proto,Args++[Rest]}})
            end
    end;

handle_event(cast, {data,Bin1}, body, {Reader0,M,A0,Ts}) ->
    case pimsg:body_reader(Reader0, Bin1) of
        {error,Reason} ->
            {stop, Reason};
        {continue,empty,Reader} ->
            {keep_state,{Reader,M,A0,Ts}};
        {continue,Bin2,Reader} ->
            A = M:body(Bin2, A0),
            {keep_state,{Reader,M,A,Ts}};
        {done,Bin2,Rest} ->
            A1 = case Bin2 of
                     empty -> A0;
                     _ -> M:body(Bin2,A0)
                 end,
            case M:reset(A1) of
                connection_close ->
                    {stop, {shutdown,closed}};
                A2 ->
                    {next_state,eof,
                     {null,M,A2,Ts},
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

%% from http11_res
error_statusln({shutdown,timeout}) -> error_statusln(http_gateway_timeout);
%% http11_res:body_length/3
error_statusln({missing_length,_,_}) -> error_statusln(http_bad_gateway);

error_statusln(Reason) ->
    case phttp:status_bin(Reason) of
        {ok,Bin} -> Bin;
        not_found ->
            {ok,Bin} = phttp:status_bin(http_bad_gateway),
            [<<?HTTP11>>," ",Bin|<<?CRLF>>]
    end.

