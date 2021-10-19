(ns piroxy.worker
  (:require [goog.object :as o]))

(js/importScripts "blert.js")

(def websock (atom nil))
(def num-fails (atom 0))
(def max-fails 5)
(def piroxy-endpoint "wss://piroxy/ws")

(defn encode-clj [x]
  (cond
    (map? x)
    (let [m (js/Map.)]
      (doseq [[k v] x]
        (.set m (encode-clj k) (encode-clj v)))
      m)
    (vector? x)
    #js{"tuple" (apply array (map encode-clj x))},
    (keyword? x)
    #js{"atom" (name x)},
    (seq? x)
    #js{"list" (apply array (map encode-clj x))},
    :else x))

(defn encode [x]
  (println (str "*DBG* sending: " (pr-str x)))
  (js/blert.encode (encode-clj x)))

(defn relay-incoming [ev]
  (let [data (o/get ev "data")]
    (..
     (js/Promise.
      (fn [resolve reject]
        (cond
          (instance? js/ArrayBuffer data) (resolve data)
          (instance? js/Blob data) (resolve (.arrayBuffer data))
          :else (reject (js/Error. "unknown websocket data type")))))
     (then #(js/postMessage (js/blert.decode %1))))))

(defn relay-outgoing [msg]
  (println "*DBG* relay-outgoing")
  (.send @websock (js/blert.encode (.-data msg))))

(defn on-open []
  (js/console.log "*DBG* WS open!")
  (.send @websock (encode [:echo "Hello, Piroxy!"])))

(defn connect []
  (when (= nil @websock)
    (let [newsock (js/WebSocket. piroxy-endpoint)]
      (set! (.-onopen newsock) on-open)
      (set! (.-onclose newsock) #(js/console.log "*DBG* WS closed!"))
      (set! (.-onerror newsock) #(js/console.log "*DBG* WS error" %1))
      (set! (.-onmessage newsock) relay-incoming)
      (reset! websock newsock))))

(set! js/onmessage relay-outgoing)
(connect)
