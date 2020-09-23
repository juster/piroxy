-define(EMPTY, empty).
-define(CRLF, 8#15, 8#12).
-define(SP, " ").
-define(HTAB, "\t").
-define(COLON, ":").
-define(HTTP11, "HTTP/1.1").

-define(HEADLN_MAX, 256).
-define(HEADER_MAX, 2048).
-define(STATUS_MAX, 256).
-define(REQUEST_MAX, 256).
-define(CHUNKSZ_MAX, 128).

-record(head, {method, line, headers, bodylen}).
-record(hstate, {buffer=?EMPTY, state=smooth, nread=0, headers=[]}).
-record(bstate, {state=smooth, nread=0, length}).
