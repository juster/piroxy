# πroxy

Pi-roxy, a personal web proxy [to be] used for investigating bug bounties and debugging web applications.

## Setup

Development is on Mac OS X. Setup is similar on any UNIX system.

1. Install Erlang.
2. Open a terminal.
   1. Change dir to source root directory.
   2. Run the gencapem escript: `./gencapem`
   3. Press *ENTER* twice and then type in a password to save a certificate in the default location.
   4. Start piroxy with a bash script: `./erl.sh`
3. Configure Firefox to use the Proxy
    1. Click the hamburger icon
    2. Click Settings
    3. Add the certificate as a trusted Certificate Authority in Firefox.
       1. Click Privacy & Security (left hand navbar).
       2. Scroll down, click *View Certificates...* button.
       3. Click *Import...* button.
       4. Browse to piroxy source root dir and look under the `priv/pem` directory. Choose `ca.pem`.
    4. Use an HTTP/HTTPS proxy.
       1. Click *General* (left hand navbar).
       2. Scroll down to *Network Settings*.
       3. Click *Settings...* button.
       4. Choose *Manual Proxy Configuration* and fill in "localhost" and "8888" for *HTTP Proxy* and *Port* text fields.
       5. Click the *Also use this proxy for HTTPS* checkbox to enable.

## Status

The underlying proxy works well! You can see debug traces from the Terminal window that indicate requests being received and forwarded to hosts. Performance is a little slower than when not using an proxy. This could be improved by tuning the number of outgoing connections per host, etc.

Next I will need to setup a web-based user interface. This will be accessible by browsing to https://piroxy . In fact it already is accessible, but there is nothing there but a blank page which opens a WebSocket to send/receive messages.

## Author

Justin Davis <jrcd83@gmail.com>
