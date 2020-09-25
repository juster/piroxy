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
-define(TARGET_FAIL_MAX, 3).
-define(REQUEST_FAIL_MAX, 5).

%% 
-define(REQUEST_TIMEOUT, 5000).

-define(DBG(Fname, T), io:format("*DBG* {~s} [~s] ~p~n", [?MODULE, Fname, T])).
-record(head, {line, method, version, headers=[], bodylen}).
-record(hstate, {buffer=?EMPTY, state=smooth, nread=0, headers=[]}).
-record(bstate, {state=smooth, nread=0, length}).
