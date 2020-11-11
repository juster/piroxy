-define(EMPTY, <<>>).
-define(CR, 8#15).
-define(LF, 8#12).
-define(CRLF, 8#15, 8#12).
-define(SP, " ").
-define(HTAB, "\t").
-define(COLON, ":").
-define(HTTP11, "HTTP/1.1").

-define(HEADLN_MAX, 16384).
-define(HEADER_MAX, 32768).
-define(STATUS_MAX, ?HEADLN_MAX).
-define(REQUEST_MAX, ?HEADER_MAX).
-define(CHUNKSZ_MAX, 16384).

%% request_manager fail count limits
-define(TARGET_FAIL_MAX, 5).
-define(REQUEST_FAIL_MAX, 5).

-define(TARGET_PROC_MAX, 1).
-define(TARGET_RESTART_PERIOD, 1).
-define(TARGET_RESTART_INTENSITY, 20).

%% outbound default request timeout
-define(REQUEST_TIMEOUT, 15000).
-define(RESPONSE_TIMEOUT, 5000).
-define(CONNECT_TIMEOUT, 15000).

-define(DBG(Fname, T), io:format("*DBG* ~p {~s} [~s]~n***** ~p~n", [self(),?MODULE,Fname,T])).
%%-define(DBG(Fname, T), ok).
-record(head, {line, method, version, headers=[], bodylen}).

-define(TRACE(Sess, Host, Dir, Str), phttp:trace(Sess,Host,Dir,Str)).
