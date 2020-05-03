-define(EMPTY, empty).
-define(CRLF, 8#15, 8#12).
-define(SP, " ").
-define(HTAB, "\t").
-define(COLON, ":").
-define(HTTP11, "HTTP/1.1").

-define(HEADER_MAX, 256).
-define(STATUS_MAX, 256).
-define(REQUEST_MAX, 256).
-define(CHUNKSZ_MAX, 128).

-record(headstate, {state=http_status, status=null, headers=[]}).
-record(bodystate, {state, nread=0, length}).
