"use strict;"
var socket
var connfail = 0
var MAX_FAIL = 5

importScripts('blert.js')

function connect(){
    socket = new WebSocket('wss://piroxy/ws')
    socket.onmessage = relay_in
    socket.onclose = connect
    //socket.onopen = function(evt){ console.log('*DBG* WS opened!') }
}

function decode_in(abuf){
    //console.log('*DBG* decoded: '+JSON.stringify(blert.decode(abuf)))
    postMessage(blert.decode(abuf))
}

function relay_out(msg){
    console.log(msg.data)
    socket.send(blert.encode(msg.data))
}

function relay_in(msg){
    if(msg.data instanceof ArrayBuffer){
        decode_in(msg.data)
    }else if(msg.data instanceof Blob){
        msg.data.arrayBuffer().then(decode_in)
    }
}

function socket_error(evt){
    if(++connfail > MAX_FAIL){
        throw new Error("connection failed "+connfail+" times")
    }else{
        connect()
    }
}

onmessage = relay_out
connect()
