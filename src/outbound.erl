-module(outbound).

-include("../include/phttp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/1, start/4, next_request/4]).

%%%
%%% EXTERNAL FUNCTIONS
%%%

%%% called by request_target

%% The pipeline proc sits between the outbound proc and the request_target
%% proc.
start_link({Proto, Host, Port}) ->
    Pid1 = spawn(?MODULE, start, [self(), Proto, binary_to_list(Host), Port]),
    Pid2 = pipipe:start_link(Pid1),
    Pid1 ! {pipepid,Pid2},
    Pid2.

%% Queue up the next request inside of the pipeline. We must notify the outbound
%% of the requesting pid (Pid2) when a new Head is sent.
next_request(Pid1, Req, Head, Pid2) ->
    pipipe:expect(Pid1, Req),
    pipipe:drip(Pid1, Req, {start,Head,Pid2}),
    ok.

%%%
%%% INTERNAL FUNCTIONS
%%%

start(Pid, http, Host, Port) ->
    case gen_tcp:connect(Host, Port, [{active,true},binary,{packet,0},
                                      {keepalive,true}],
                         ?CONNECT_TIMEOUT) of
        {error, Reason} ->
            exit(Reason);
        {ok, Sock} ->
            start2(Pid, {tcp,Sock})
    end;

start(Pid, https, Host, Port) ->
    case ssl:connect(Host, Port, [{active,true},binary,{packet,0},
                                  {keepalive,true}],
                     ?CONNECT_TIMEOUT) of
        {error,Reason} ->
            exit(Reason);
        {ok,Sock} ->
            ssl:setopts(Sock, [{active,true}]),
            start2(Pid, {ssl,Sock}, Host)
    end.

start2(PidT, Sock) ->
    process_flag(trap_exit, true),
    {ok,PidH} = http11_statem:start_link({?RESPONSE_TIMEOUT, 60000}, []),
    PidP = receive {pipepid, Pid1} -> Pid1 end,
    request_target:ready(PidT, PidP),
    loop(Sock, {PidT,PidP,PidH}).

start2(PidT, Sock, Host) ->
    process_flag(trap_exit, true),
    {ok,PidH} = case Host of
                    "alb.reddit.com" ->
                        http11_statem:start_link({?RESPONSE_TIMEOUT, 60000}, [{debug,[trace]}]);
                    _ ->
                        http11_statem:start_link({?RESPONSE_TIMEOUT, 60000}, [])
                end,
    PidP = receive {pipepid, Pid1} -> Pid1 end,
    request_target:ready(PidT, PidP),
    loop(Sock, {PidT,PidP,PidH}).


loop(Sock, Pids) ->
    loop(Sock, Pids, {[],false}).

loop(Sock, Pids, {Q,Close}=State) ->
    receive
        %% messages from pipipe
        {pipe,Req,{start,Head,PidI}} ->
            %% pipeline the next request ASAP
            {Pid1,Pid2,_} = Pids,
            Host = fieldlist:get_value(<<"host">>, Head#head.headers),
            Line = if
                       length(Head#head.line) > 60 ->
                           lists:sublist(Head#head.line, 1, 60) ++ "...";
                       true ->
                           Head#head.line
                   end,
            io:format("[~B] (~s) -> ~s~n", [Req, Host, Line]),
            request_target:ready(Pid1, Pid2),
            send(Sock, phttp:encode(Head)),
            loop(Sock, Pids, {Q ++ [{Req,Head,PidI}], Close});
        {pipe,_Req,eof} ->
            loop(Sock, Pids, State);
        {pipe,_Req,Term} ->
            send(Sock, phttp:encode(Term)),
            loop(Sock, Pids, State);
        %% messages from http11_statem
        {http, {head,StatusLn,Headers}} ->
            H = head(StatusLn, Headers, hd(Q)),
            http11_statem:expect_bodylen(element(3,Pids), H#head.bodylen),
            http(Sock, Pids, State, H);
        {http,Term} ->
            http(Sock, Pids, State, Term);
        {tcp, _Sock, Data} ->
            http11_statem:read(element(3,Pids), Data),
            loop(Sock, Pids, State);
        {tcp_closed,_} ->
            http11_statem:shutdown(element(3,Pids), closed),
            loop(Sock, Pids, State);
        {tcp_error,Reason} ->
            ?DBG("loop", [{tcp_error,Reason}]),
            http11_statem:shutdown(element(3,Pids), Reason),
            loop(Sock, Pids, State);
        {ssl, _Sock, Data} ->
            http11_statem:read(element(3,Pids), Data),
            loop(Sock, Pids, State);
        {ssl_closed,_} ->
            %%?DBG("loop", ssl_closed),
            http11_statem:shutdown(element(3,Pids), closed),
            loop(Sock, Pids, State);
        {ssl_error,Reason} ->
            ?DBG("loop", [{ssl_error,Reason}]),
            http11_statem:shutdown(element(3,Pids), Reason),
            loop(Sock, Pids, State);
        {'EXIT',_,Reason} ->
            %%?DBG("loop", [{reason,Reason}]),
            exit(Reason);
        Any ->
            exit({unknown_msg,Any})
    end.

http(Sock, Pids, {Q0, Close0}=State, Term) ->
    [{Req,Head,PidI}|Q] = Q0,
    pipipe:drip(PidI, Req, Term),
    case Term of
        #head{} ->
            Close = connection_close(Term),
            loop(Sock, Pids, {Q0,Close});
        eof ->
            %%?DBG("http", [eof,{req,Req},{pidi,PidI}]),
            request_target:finish(element(1,Pids), Req),
            case Close0 of
                true ->
                    Host = fieldlist:get_value(<<"host">>, Head#head.headers),
                    io:format("[~B] (~s) EOF -> ~p~n", [Req, Host,PidI]),
                    %%?DBG("http", closing),
                    exit({shutdown,closed});
                false ->
                    loop(Sock, Pids, {Q,false})
            end;
        _ ->
            loop(Sock, Pids, State)
    end.

send({tcp,Sock}, Bin) ->
    gen_tcp:send(Sock, Bin);

send({ssl,Sock}, Bin) ->
    ssl:send(Sock, Bin).

head(StatusLn, Headers, {_Req,Head,_PidI}) ->
    Method = Head#head.method,
    Len = body_length(StatusLn, Headers, Head),
    #head{method=Method, line=StatusLn, headers=Headers, bodylen=Len}.

body_length(StatusLn, Headers, ReqH) ->
    %% the response length depends on the request method
    Method = ReqH#head.method,
    case response_length(Method, StatusLn, Headers) of
        {ok,0} -> 0;
        {ok,BodyLen} -> BodyLen;
        {error,{missing_length,_}} ->
            exit({missing_length,StatusLn,Headers})
    end.

response_length(Method, Line, Headers) ->
    response_length_(Method, response_code(Line), Headers).

response_length_(head, <<"200">>, _) -> {ok, 0};
response_length_(_, <<"200">>, Headers) -> pimsg:body_length(Headers);
response_length_(_, <<"1",_,_>>, _) -> {ok, 0};
response_length_(_, <<"204">>, _) -> {ok, 0};
response_length_(_, <<"304">>, _) -> {ok, 0};
response_length_(head, _, _) -> {ok, 0};
response_length_(_, _, ResHeaders) -> pimsg:body_length(ResHeaders).

response_code(StatusLn) ->
    case phttp:nsplit(3, StatusLn, <<" ">>) of
        {ok,[_,Status,_]} ->
            Status;
        {error,Reason} ->
            error(Reason)
    end.

%%% TODO: double-check RFC7231 for other values
connection_close(#head{headers=Headers}) ->
    case fieldlist:get_value(<<"connection">>, Headers) of
        <<"close">> ->
            %%?DBG("connection_close", {connection,<<"close">>}),
            true;
        Bin ->
            %%?DBG("connection_close", {connection,Bin}),
            false
    end.


