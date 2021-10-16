(ns piroxy.worker
  (:require [goog.object :as o]))

(js/importScripts "blert.js")

(def websock (atom nil))
(def num-fails (atom 0))
(def max-fails 5)
(def piroxy-endpoint "wss://piroxy/ws")

(defn decode-erl [x]
  (cond
    (string? x) x
    (number? x) x
    (instance? js/Map x)
    (reduce (fn [m a]
              (let [k (decode-erl (aget a 0))
                    v (decode-erl (aget a 1))]
                (assoc m k v))) {} (.entries x)) ;;js/Array.from array-seq))
    (object? x)
    (cond
      (o/contains x "atom")
      (keyword (o/get x "atom"))
      (o/contains x "tuple")
      (vec (map decode-erl (array-seq (o/get x "tuple"))))
      (o/contains x "list")
      (map decode-erl (array-seq (o/get x "list")))
      :else
      (throw (js/Error. "unrecognized erlang object")))))

(defn decode [buffer]
  (let [erl (js/blert.decode buffer)]
    (decode-erl erl)))

(defn encode-clj [x]
  (cond
    (map? x)
    (reduce (fn [map [k v]] (.add map (encode-clj k) (encode-clj v))) (js/Map.) x)
    (vector? x)
    #js{"tuple" (apply array (map encode-clj x))}
    (keyword? x)
    #js{"atom" (name x)}
    (seq? x)
    #js{"list" (apply array (map encode-clj x))}
    :else x))

(defn encode [x]
  (js/blert.encode (encode-clj x)))

(defn relay-incoming [ev]
  (let [data (.-data ev)]
    (cond
      (instance? js/ArrayBuffer data) (js/postMessage (decode data))
      (instance? js/Blob data) (.. data (arrayBuffer) (then #(js/postMessage (decode %1)))))))

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

(connect)
