/* The simplest possible WebSocket example.
 * The server echos back what it receives from the client.
 */

const http = require("http")
const crypto = require("crypto")
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

function indexPage(req, res) {
    res.writeHead(200, {"content-type": "text/html"})
    res.end(`<!DOCTYPE html>
<html><body>
<form>
<div>
  <input type=button name=connect value="Connect">
  <input type=button name=close value="Close">
</div>
<div><input type=text name=txt size=40><input type=button name=send value="Send"></div>
</form>
<div id=out>
<h1>Output</h1>
</div>
<script type="text/javascript">
var ws = null

function write(msg) {
    document.getElementById("out").innerHTML += "<div>"+msg+"</div>"
}

function connect() {
    if(ws != null) {
        write("error: already connected")
        return
    }
    ws = new WebSocket("ws://localhost:9999/")
    ws.onopen = function(ev){
        write("Connected.")
    }
    ws.onmessage = function(ev){
        write("<<< "+ev.data)
    }
    ws.onclose = function(ev){
        write("Closed.")
        ws = null
    }
}

function disconnect() {
    if(ws == null) {
        write("error: not connected")
        return
    }
    ws.close()
}

function send() {
    if(ws == null) {
        write("error: not connected")
        return
    }
    ws.send(f.txt.value)
    write(">>> "+f.txt.value)
}

var f = document.forms[0]
f.connect.onclick = connect
f.close.onclick = disconnect
f.send.onclick = send
f.onsubmit = function(ev){ ev.preventDefault() }
</script>
</body></html>
`)
}

function httpHandler(req, res) {
    if(req.method === "GET" && req.url === "/") {
        indexPage(req, res)
        return
    } else {
        res.writeHead(404, {"content-type": "text/plain; charset=utf-8"})
        res.end("404 Not found\r\n")
    }
}

function wsHandler(req, sock, head) {
    const wsUpgrade = /websocket/i.test(req.headers.upgrade)
    const wsConnection = /upgrade/i.test(req.headers.connection)
    const wsVersion = req.headers["sec-websocket-version"]
    if (req.url !== "/" || !wsConnection || !wsUpgrade || wsVersion != "13") {
        sock.write("HTTP/1.1 501 Not Implemented\r\n\r\n")
        sock.end()
        return
    }
    let hash = crypto.createHash("sha1")
    hash.write(req.headers["sec-websocket-key"])
    hash.write(WS_GUID)
    hash.end()
    let accept = hash.digest("base64")

    sock.write(`HTTP/1.1 101 WEBSOCK IT TO ME BABY\r
Upgrade: Websocket\r
Connection: upgrade\r
Sec-Websocket-Accept: ${accept}\r
\r\n`)
    sock.write(head)
    //sock.on("data", (buf) => sock.write(buf))
    sock.pipe(sock)
    sock.on("end", () => console.log("websocket closed"))
    console.log("websocket opened")
}

function main() {
    let server = http.createServer()
    server.on("request", httpHandler)
    server.on("upgrade", wsHandler)
    server.listen(9999)
}

if (require.main === module) {
    main()
}
