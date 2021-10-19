(ns piroxy.core
  (:require [goog.object :as o]
            [piroxy.blert :as blert]))

(def worker (atom nil))
(def n-error (atom 0))
(def max-error 5)

(defn worker-error [err]
  (js/console.error (str "Worker error: " (.-message err)))
  (swap! n-error inc)
  (when (<= @n-error max-error)
    (swap! worker
          (fn [w]
            (.terminate @worker)
            (new-worker)))))

(defn worker-msg [msg]
  (let [clj (blert/decode (.-data msg))]
    (js/console.log "Worker message: " (pr-str clj))))

(defn ticker []
  (.postMessage @worker
                (blert/encode [:echo [{:hello :piroxy}
                                      "how are you?"
                                      (seq [1.01 2.02 3.03])]])))

(defn new-worker []
  (let [w (js/Worker. "worker.js")]
    (set! (.-onerror w) worker-error)
    (set! (.-onmessage w) worker-msg)
    w))

(reset! worker (new-worker))
(js/setInterval ticker 5000)
