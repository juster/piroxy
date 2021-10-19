(ns piroxy.blert
  (:require [goog.object :as o]))

(defn decode [x]
  (cond
    (boolean? x) x
    (string? x) x
    (number? x) x
    (instance? js/Map x)
    (let [k (map decode (.keys x))
          v (map decode (.values x))]
      (zipmap k v))
    (object? x)
    (cond
      (o/containsKey x "atom")
      (keyword (o/get x "atom"))
      (o/containsKey x "tuple")
      (vec (map decode (array-seq (o/get x "tuple"))))
      (o/containsKey x "list")
      (map decode (array-seq (o/get x "list")))
      :else
      (do
        (js/console.log "*DBG*" x)
        (throw (js/Error. "unrecognized erlang object"))))))

(defn encode [x]
  (cond
    (map? x)
    (let [m (js/Map.)]
      (doseq [[k v] x]
        (.set m (encode k) (encode v)))
      m)
    (vector? x)
    #js{"tuple" (apply array (map encode x))},
    (keyword? x)
    #js{"atom" (name x)},
    (seq? x)
    #js{"list" (apply array (map encode x))},
    :else x))
