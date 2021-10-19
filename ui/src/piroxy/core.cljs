(ns piroxy.core
  (:require [goog.object :as o]))

(def worker (atom nil))

(defn worker-error [err]
  (js/console.error (str "Worker error: " (.-message err))))

(defn decode-blert [x]
  (cond
    (boolean? x) x
    (string? x) x
    (number? x) x
    (instance? js/Map x)
    (let [k (map decode-blert (.keys x))
          v (map decode-blert (.values x))]
      (zipmap k v))
    (object? x)
    (cond
      (o/containsKey x "atom")
      (keyword (o/get x "atom"))
      (o/containsKey x "tuple")
      (vec (map decode-blert (array-seq (o/get x "tuple"))))
      (o/containsKey x "list")
      (map decode-blert (array-seq (o/get x "list")))
      :else
      (do
        (js/console.log "*DBG*" x)
        (throw (js/Error. "unrecognized erlang object"))))))

(defn worker-msg [msg]
  (let [clj (decode-blert (.-data msg))]
    (js/console.log "Worker message: " (pr-str clj))))

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

(defn ticker []
  (.postMessage @worker
                (encode-clj [:echo [{:hello :piroxy}
                                    "how are you?"
                                    (seq [1.01 2.02 3.03])]])))

(defn init []
  (let [w (js/Worker. "worker.js")]
    (set! (.-onerror w) worker-error)
    (set! (.-onmessage w) worker-msg)
    (reset! worker w))
  (js/setInterval ticker 5000))

(init)
