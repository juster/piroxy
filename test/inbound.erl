-module(inbound).

-compile(export_all).

close_request(Pid, Ref) ->
    Pid ! {close_request, Ref}.

reset_request(Pid, Ref) ->
    Pid ! {reset, Ref}.

request_body(Pid, Ref) ->
    Pid ! {get_request_body, self(), Ref},
    receive
        {request_body_is, Body} ->
            {last, Body}
    end.

response_head(Pid, Ref, Status, Headers) ->
    Pid ! {response_head, Ref, Status, Headers}.

response_body(Pid, Body) ->
    Pid ! {response_body, Body}.

abort_request(Pid, Ref, Reason) ->
    Pid ! {abort_request, Ref, Reason}.

%%%

request(HostInfo, Request) ->
    spawn_link(?MODULE, start, [HostInfo, Request]).

start(HostPort, Request) ->
    case request_manager:new_request(HostPort, Request) of
        {error, Reason} ->
            error(Reason);
        Ref ->
            io:format("started request: ~p~n", [Ref]),
            loop(Ref, empty)
    end.

loop(Ref, Body) ->
    receive
        {close_request, Ref} ->
            io:format("closing request...~n"),
            ok;
        {abort_request, Ref, Reason} ->
            io:format("request aborted! reason: ~w~n", [Reason]),
            error(Reason);
        {get_request_body, Pid, Ref} ->
            Pid ! {request_body_is, Body},
            loop(Ref, Body);
        {response_head, Ref, {{Major, Minor}, Status, _}, Headers} ->
            io:format("STATUS: ~s (HTTP ~B.~B)~nHEADERS~n~s"
                "----------------------------------------"
                "------------------------------~n",
                [Status, Major, Minor, fieldlist:to_iolist(Headers)]),
            loop(Ref, Body);
        {response_body, RespBody} ->
            io:format("BODY~n"
                      "----------------------------------------"
                      "------------------------------~n"
                      "~s"
                      "----------------------------------------"
                      "------------------------------~n",
                      [RespBody]),
            loop(Ref, Body);
        Msg ->
            io:format("received msg: ~w~n", [Msg]),
            loop(Ref, Body)
    end.
