# piroxy

Flutter app for the embedded web application.

## Overview

This web app is hosted by piroxy itself. When a request is received for the
"piroxy" host then the proxy hijacks the connections and serves the webapp in a
stupid simple web server. The assets are fetched with GET requests but most of
the work is done over a web socket.

The binary erlang term format is used to communicate over the websocket. This
functions much the same as JSON, except it is more of a pain for JavaScript to
use and trivial for Erlang to use. The two files under js/ are used to create a
WebWorker that is used to encode/decode the messages between the server.

- js/blert.js
- js/worker.js

The worker is very simple. When started it loads _blert.js_, connects to the
`https://piroxy/ws` WebSocket, then shuttles messages between the webapp and the
socket. Messages from the webapp are encoded and transmitted. Bytes are
received, decoded with blert, and posted to the app. Blert is inspired by
[BERT](http://bert-rpc.org), a well-intentioned but mostly dead protocol which
is a ripoff of Erlang term format.

## Future?

For now the platforms other than web are useless. I have committed the default
skeleton files creates by `flutter create` anyways. One day it may be nice to
have a client available as an alternative to the embedded we bapp. Having an iOS
app that shows requests scrolling by sounds really cool; especially if it
somehow links to the embedded webapp as an addition to the user interface.
