"use strict;"
let socket
let fails = 0
const MAX_FAIL = 5

importScripts('blert.js')

function connect(){
    socket = new WebSocket('wss://piroxy/ws')
    socket.onmessage = relay_in
    socket.onclose = function(){
        socket = null
        console.log("*DBG* WS closed!")
        throw new Error("WS closed")
    }
    socket.onopen = function(evt){ console.log('*DBG* WS opened!') }
    socket.onerror = reconnect
}

function decode_in(abuf){
    //console.log('*DBG* decoded:', JSON.stringify(blert.decode(abuf)))
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

function reconnect(evt){
    if(++fails > MAX_FAIL){
        throw new Error("connection failed "+fails+" times")
    }else{
        connect()
    }
}

onmessage = relay_out
connect()
