-module(outbound).

-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").
-import(erlang, [system_time/0, convert_time_unit/3]).
-import(lists, [foreach/2]).

-export([start_link/1, start/4, next_request/3]).

%%%
%%% EXTERNAL FUNCTIONS
%%%

%% called by request_target
start_link({http, Host, Port}) ->
    {ok,spawn_link(?MODULE, start, [self(), binary_to_list(Host), Port, false])};

start_link({https, Host, Port}) ->
    {ok,spawn_link(?MODULE, start, [self(), binary_to_list(Host), Port, true])}.

%% notify the outbound Pid that a new request is ready for it to send/recv
next_request(Pid, Req, Head) ->
    Pid ! {stream,{Req,Head}},
    ok.

%%%
%%% INTERNAL FUNCTIONS
%%%

start(Pid, Host, Port, false) ->
    case gen_tcp:connect(Host, Port, [{active,true},binary,{packet,0},
                                      {keepalive,true}],
                         ?CONNECT_TIMEOUT) of
        {error, Reason} ->
            exit(Reason);
        {ok, Sock} ->
            start2(Pid, {tcp,Sock})
    end;

start(Pid, Host, Port, true) ->
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0},
                                  {keepalive,true}],
                     ?CONNECT_TIMEOUT) of
        {error,Reason} ->
            exit(Reason);
        {ok,Sock} ->
            ssl:setopts(Sock, [{active,true}]),
            start2(Pid, {ssl,Sock})
    end.

start2(TargetPid, Sock) ->
    process_flag(trap_exit, true),
    M = http11_res,
    {ok,StmPid} = M:start_link([TargetPid]),
    request_target:need_request(TargetPid),
    loop(TargetPid, Sock, M, StmPid).

loop(Pid, Sock, M, A) ->
    receive
        Any ->
            %% process messages in order they are received
            case Any of
                {stream,Term} ->
                    %% sent from request_target, morgue (http streams),
                    %% or piserver (raw_streams)
                    M:push(A, Sock, Term),
                    case Term of
                        {Req,#head{}} ->
                            %% XXX: special logic for HTTP request head messages...
                            request_target:need_request(Pid);
                        _ ->
                            ok
                    end,
                    loop(Pid, Sock, M, A);
                {tcp, _, <<>>} ->
                    loop(Pid, Sock, M, A);
                {tcp, _Sock, Data} ->
                    M:read(A, Data),
                    loop(Pid, Sock, M, A);
                {ssl, _, <<>>} ->
                    loop(Pid, Sock, M, A);
                {ssl, _Sock, Data} ->
                    M:read(A, Data),
                    loop(Pid, Sock, M, A);
                {tcp_closed,_} ->
                    M:shutdown(A, closed),
                    loop(Pid, Sock, M, A);
                {ssl_closed,_} ->
                    M:shutdown(A, closed),
                    loop(Pid, Sock, M, A);
                {tcp_error,Reason} ->
                    ?DBG("loop", [{tcp_error,Reason}]),
                    M:shutdown(A, Reason),
                    loop(Pid, Sock, M, A);
                {ssl_error,Reason} ->
                    ?DBG("loop", [{ssl_error,Reason}]),
                    M:shutdown(A, Reason),
                    loop(Pid, Sock, M, A);
                {'EXIT',_StmPid,{shutdown,{upgraded,M_,InitA}}} ->
                    {ok,A_} = M_:start_link(InitA),
                    request_target:retire_self(Pid),
                    unlink(Pid),
                    %% XXX: we should probably not keep looping with Pid?!
                    loop(Pid, Sock, M_, A_);
                {'EXIT',_StmPid,Reason} ->
                    %%?DBG("loop", [{reason,Reason}]),
                    exit(Reason);
                _ ->
                    exit({unknown_msg,Any})
            end
    end.
