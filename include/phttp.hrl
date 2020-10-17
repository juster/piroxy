-define(EMPTY, empty).
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
-define(TARGET_FAIL_MAX, 2).
-define(REQUEST_FAIL_MAX, 5).

%% outbound default request timeout
-define(REQUEST_TIMEOUT, 5000).
-define(CONNECT_TIMEOUT, 15000).

-define(DBG(Fname, T), io:format("*DBG* ~p {~s} [~s] ~p~n", [self(),?MODULE,Fname,T])).
%%-define(DBG(Fname, T), ok).
-record(head, {line, method, version, headers=[], bodylen}).
