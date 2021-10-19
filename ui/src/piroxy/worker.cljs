(ns piroxy.worker)

(js/importScripts "blert.js")

(def websock (js/WebSocket. "wss://piroxy/ws"))

(defn relay-incoming [ev]
  (let [data (.-data ev)]
    (->
     (js/Promise.
      (fn [resolve reject]
        (cond
          (instance? js/ArrayBuffer data) (resolve data)
          (instance? js/Blob data) (resolve (.arrayBuffer data))
          :else (reject (js/Error. "unknown websocket data type")))))
     (.then #(js/postMessage (js/blert.decode %1))))))

(defn relay-outgoing [msg]
  (.send websock (js/blert.encode (.-data msg))))

(defn on-open []
  (js/console.log "*DBG* WS open!"))

(defn on-close []
  (js/console.log "*DBG* WS closed!")
  (js/close))

(set! (.-onopen websock) on-open)
(set! (.-onclose websock) on-close)
;;(set! (.-onerror websock) #(throw %1))
(set! (.-onmessage websock) relay-incoming)
(set! js/onmessage relay-outgoing)
