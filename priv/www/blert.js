/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

"use strict";
(function(){

var exports = {
    alloc, encode, decode,
    isAtom, isTuple, isList, isProper
}
if(typeof module !== "undefined"){
    module.exports = exports
}else if(typeof globalThis !== "undefined"){
    globalThis.blert = exports
}else if(typeof self !== "undefined"){
    self.blert = exports
}else if(typeof window !== "undefined"){
    window.blert = exports
}

var ETF_MAGIC = 131
var INFLATE = 80
var SMALL_INTEGER_EXT = 97
var INTEGER_EXT = 98
var FLOAT_EXT = 99 //unimplemented
var MAP_EXT = 116
var SMALL_TUPLE_EXT = 104
var LARGE_TUPLE_EXT = 105
var NIL_EXT = 106
var STRING_EXT = 107
var LIST_EXT = 108
var BINARY_EXT = 109
var SMALL_BIG_EXT = 110
var LARGE_BIG_EXT = 111
var BIT_BINARY_EXT = 77
var NEW_FLOAT_EXT = 70
var ATOM_UTF8_EXT = 118
var SMALL_ATOM_UTF8_EXT = 119
var ATOM_EXT = 100 //deprecated
var SMALL_ATOM_EXT = 115 //deprecated

var blert_buffer = null

var null_buf = new Uint8Array(110,117,108,108)
var true_buf = new Uint8Array(116,114,117,101)
var false_buf = new Uint8Array(102,97,108,115,101)

alloc(4096)

function alloc(nbuf){
    blert_buffer = new ArrayBuffer(nbuf)
    new DataView(blert_buffer).setUint8(0, ETF_MAGIC)
}

function encode(x){
    var V = new DataView(blert_buffer)
    var n = enc(x, 1, V)
    return blert_buffer.slice(0, n+1) // Copy the bytes out of the buffer.

    function enci(x, i, V){
        if(-128 <= x && x <= 127){
            V.setUint8(i+0, SMALL_INTEGER_EXT)
            V.setInt8(i+1, x)
            return 2
        }else if(-2147483648 <= x && x <= 2147483647){
            V.setUint8(i+0, INTEGER_EXT)
            V.setInt32(i+1, x)
            return 5
        }else{
            // ETF decompose an integer into an array of base256 digits.
            var A=[]
            var sgn = (Math.sign(x) >= 0)
            x = Math.abs(x) //XXX: overwrites param
            while(x != 0){
                // We cannot use bitwise operators because they explicitly limit a
                // number to 32-bits in JavaScript.
                A.push(y % 256)
                x = Math.floor(x / 256)
            }
            if(A.length <= 255){
                V.setUint8(i+0, SMALL_BIG_EXT)
                V.setUint8(i+1, A.length)
                V.setUint8(i+2, (x > 0 ? 0 : 1))
                new Uint8Array(V.buffer, i+3, A.length).set(A)
                return A.length+3
            }else{
                throw new Error("integer too large") // use BigInt instead
            }
        }
    }

    function encf(d, i, V){
        V.setUint8(i+0, NEW_FLOAT_EXT)
        V.setFloat64(i+1, d)
        return 9
    }

    // BigInt-egers are encoded/decoded using LARGE_BIG_EXT exclusively, even
    // if they would fit in SMALL_BIG_EXT, etc. This way we do not accidentally
    // convert between Number/BigInt when encoding/decoding.
    function encbi(y, i, V){
        var A=[]
        var j=0
        var sgn = (y >= 0 ? 0 : 1)
        while(y != 0 && y != -1){
            // Bitwise operators are safe with BigInt.
            A.push(Number(y & BigInt(255)))
            y >>= BigInt(8)
        }
        V.setUint8(i+0, LARGE_BIG_EXT)
        V.setUint32(i+1, A.length)
        V.setUint8(i+5, sgn)
        for(j=0; j<A.length; j++) V.setUint8(i+j+6, A[j])
        return j+6
    }

    function encl(L, i, V){
        if(L.list.length === 0 && isProper(L)){
            // NOTE: this matches `nil' AND any other zero-length proper list
            V.setUint8(i, NIL_EXT)
            return 1
        }else if(
            L.list instanceof Uint8Array && isProper(L) && L.list.length <= 65535
        ){
            // STRING_EXT can only contain bytes.
            // STRING_EXT has an implicit tail element of [].
            // STRING_EXT size must fit in 16 bits.
            var A = L.list
            V.setUint8(i, STRING_EXT)
            V.setUint16(i+1, A.length)
            new Uint8Array(V.buffer, i+3, A.length).set(A) // no assignment needed!
            return 3+A.length
        }else if(L.list.length <= 4294967295){
            // LIST_EXT can contain elements with arbitrary types.
            // LIST_EXT explicitly stores a tail element of arbitrary type.
            // LIST_EXT size must fit in 32 bits.
            var A = L.list
            V.setUint8(i+0, LIST_EXT)
            V.setUint32(i+1, A.length)
            for(var j=0, n=5; j<A.length; j++) n += enc(A[j], i+n, V)
            if(!("tail" in L)){
                V.setUint8(i+n, NIL_EXT)
                return n+1
            }else{
                return n + enc(L.tail, i+n, V)
            }
        }else{
            throw new Error("list too long")
        }
    }

    function enct(T, i, V){
        var A = T.tuple
        if(A.length <= 255){
            V.setUint8(i+0, SMALL_TUPLE_EXT)
            V.setUint8(i+1, A.length)
            for(var j=0, n=2; j<A.length; j++) n += enc(A[j], i+n, V)
            return n
        }else{
            V.setUint8(i+0, LARGE_TUPLE_EXT)
            V.setUint32(i+1, A.length)
            for(var j=0, n=5; j<A.length; j++) n += enc(A[j], i+n, V)
            return n
        }
    }

    function encm(M, i, V){
        if(M.size > 4294967295){
            throw new Error("Map too large")
        }
        V.setUint8(i+0, MAP_EXT)
        V.setUint32(i+1, M.size)
        var j=5
        for(var k of M.keys()){
            j += enc(k, i+j, V)
            j += enc(M.get(k), i+j, V)
        }
        return j
    }

    function enca(a, i, V){
        if(a.length <= 255){
            V.setUint8(i+0, SMALL_ATOM_UTF8_EXT)
            V.setUint8(i+1, a.length)
            new Uint8Array(V.buffer, i+2, a.length).set(a)
            return a.length+2
        }else if(a.length <= 65535){
            V.setUint8(i+0, ATOM_UTF8_EXT)
            V.setUint16(i+1, a.length)
            new Uint8Array(V.buffer, i+3, a.length).set(a)
            return a.length+3
        }else{
            throw new Error("atom too long")
        }
    }

    function encb(A8, i, V){
        V.setUint8(i+0, BINARY_EXT)
        V.setUint32(i+1, A8.length)
        new Uint8Array(V.buffer, i+5, A8.length).set(A8)
        return A8.length+5
    }

    function enc(X, i, V){
        switch(typeof X){
            case "boolean":
                return enca(X ? true_buf : false_buf, i, V)
            case "number":
                if(Number.isInteger(X)){
                    return enci(X, i, V)
                }else{
                    return encf(X, i, V)
                }
            case "bigint":
                // If a JavaScript does not support BigInt, this will simply
                // never be called.
                return encbi(X, i, V)
            case "string":
                return encl({list: new TextEncoder().encode(X)}, i, V)
            case "object":
                if(X === null){
                    return enca(null_buf, i, V)
                }else if(X instanceof Uint8Array){
                    return encb(X, i, V)
                }else if(X instanceof Map){
                    return encm(X, i, V)
                }else if(isAtom(X)){
                    switch(X.atom){
                        case undefined:
                            // should never happen
                            throw new Error("internal error")
                        case "true":
                        case "false":
                        case "null":
                            // If we encode these, they will be decoded as javascript
                            // literals.
                            console.warn("blert: "+atomName(X)+" is "+
                                "encoded as atom but would be decoded "+
                                "as JavaScript primitive")
                            throw new Error("bad atom: "+X)
                        default:
                            return enca(new TextEncoder().encode(X.atom), i, V)
                    }
                }else if(isList(X)){
                    return encl(X, i, V)
                }else if(isTuple(X)){
                    return enct(X, i, V)
                }else{
                    throw new Error("bad object: "+JSON.stringify(X))
                }
            default:
                throw new Error("bad type: "+typeof(X))
        }
    }
}

function decode(A){
    if(A.length == 0){
        throw new Error("bad argument")
    }
    try{
        var V = new DataView(A)
        if(V.getUint8(0) == ETF_MAGIC){
            var R = dec(1, V)
            if(R[0] < A.length-1){
                throw new Error("leftover bytes")
                //console.warn(A.length-R[0]-1 + " leftover bytes after ETF "+
                //    "decode")
            }else if(R[0] > A.length-1){
                throw new Error("read past buffer?")
            }
            return R[1]
        }else{
            throw new Error("invalid ETF magic")
        }
    }catch(err){
        if(err instanceof RangeError){
            throw new Error("incomplete ETF")
        }else{
            throw err
        }
    }

    function dec(i, V){
        if(isNaN(i)){
            throw new Error("internal error")
        }
        var n, R, x
        switch(V.getUint8(i)){
            case SMALL_INTEGER_EXT:
                x = V.getInt8(i+1)
                return [2, x]
            case INTEGER_EXT:
                x = V.getInt32(i+1)
                return [5, x]
            case FLOAT_EXT:
                throw new Error("FLOAT_EXT unimplemented")
            case SMALL_TUPLE_EXT:
                n = V.getUint8(i+1)
                return decn(i, 2, n, V, mapt)
            case LARGE_TUPLE_EXT:
                n = V.getUint32(i+1)
                return decn(i, 5, n, V, mapt)
            case MAP_EXT:
                n = V.getUint32(i+1)
                return decn(i, 5, n*2, V, mapm)
            case NIL_EXT:
                // Nil means [] in Erlang. Generate a new empty array.
                return [1, {list:[], tail:nil}]
            case STRING_EXT:
                // "Strings" are just lists whose elements are codepoints.
                n = V.getUint16(i+1)
                x = new Uint8Array(V.buffer, i+3, n)
                return [n+3, new TextDecoder().decode(x)]
            case LIST_EXT:
                n = V.getUint32(i+1)
                x = decn(i, 5, n, V, mapid)
                if(V.getUint8(i+x[0]) === NIL_EXT){
                    return [x[0]+1, {list:x[1]}]
                }else{
                    R = dec(i+x[0], V)
                    return [x[0]+R[0], {list:x[1], tail:R[1]}]
                }
            case BINARY_EXT:
                n = V.getUint32(i+1)
                x = new Uint8Array(new Uint8Array(V.buffer, i+5, n))
                return [n+5, x]
            case SMALL_BIG_EXT:
                n = V.getUint8(i+1)
                x = V.getUint8(i+2) // sign
                return deci(i, 3, n, V, x)
            case LARGE_BIG_EXT:
                n = V.getUint32(i+1)
                x = V.getUint8(i+5) //sign
                return decbi(i, 6, n, V, x)
            case BIT_BINARY_EXT:
                throw new Error("BIT_BINARY_EXT unimplemented")
            case NEW_FLOAT_EXT:
                x = V.getFloat64(i+1)
                return [9, x]
            case ATOM_UTF8_EXT:
                n = V.getUint16(i+1)
                return [n+3, deca(i+3, V, n, "utf-8")]
            case SMALL_ATOM_UTF8_EXT:
                n = V.getUint8(i+1)
                return [n+2, deca(i+2, V, n, "utf-8")]
            case ATOM_EXT:
                n = V.getUint16(i+1)
                return [n+3, deca(i+3, V, n, "windows-1252")]
            case SMALL_ATOM_EXT:
                n = V.getUint8(i+1)
                return [n+2, deca(i+2, V, n, "windows-1252")]
                throw new Error("SMALL_ATOM_EXT unimplemented")
            default:
                console.error("blert: unexpected byte "+V.getUint8(i)+" at "+i)
                throw new Error("invalid byte")
        }

        function mapid(x){
            return x
        }

        function mapt(A){
            return {tuple:A}
        }

        function mapm(A){
            var M = new Map()
            for(var i=0; i<A.length; i+=2) M.set(A[i], A[i+1])
            return M
        }

        function decstr(i, V, n, encoding){
            var A = new Uint8Array(V.buffer, i, n)
            return new TextDecoder(encoding).decode(A)
        }

        function deca(i, V, n, encoding){
            x = decstr(i, V, n, encoding)
            switch(x){
                case "null":
                    return null
                case "true":
                    return true
                case "false":
                    return false
                default:
                    return {atom:x}
            }
        }

        function decn(i,m,n,V,f){
            var A = new Array(n)
            var k=0
            for(var j=0; j<n; j++){
                // I would use destructuring here, but I worry about support in
                // browsers.
                var B = dec(i+m+k, V)
                k += B[0]; A[j] = B[1]
            }
            return [m+k, f(A)]
        }

        function deci(i,m,n,V,sgn){
            var x=0
            for(var j=0, y=1; j<n; j++, y*=256){
                x += V.getUint8(i+m+j) * y
            }
            return [m+n, (sgn ? -1*x : x)]
        }

        function decbi(i,m,n,V,sgn){
            if(typeof(BigInt) !== "function"){
                throw new Error("BigInt support missing")
            }else{
                var y = BigInt(0)
                for(var j=0; j<n; j++) y += BigInt(V.getUint8(i+j+m)) << BigInt(8*j)
                return [m+n, y]
            }
        }
    }
}

function isAtom(A){
    return typeof A === "object" && "atom" in A
}

function isTuple(T){
    return typeof T === "object" && "tuple" in T
}

function isList(L){
    // NOTE: nil is a list
    return typeof L === "object" && "list" in L
}

function isProper(L){
    // NOTE: specifying a "tail" is optional!
    return isList(L) && !("tail" in L)
}

})() // end of module wrapper function
