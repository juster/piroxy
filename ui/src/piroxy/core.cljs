(ns piroxy.core
  (:require [goog.object :as o]
            [piroxy.blert :as blert]
            [piroxy.component :as c :include-macros]))

(def worker (atom nil))
(def n-error (atom 0))
(def max-error 5)

(defn new-worker []
  (letfn [(onmsg [msg]
            (let [clj (blert/decode (.-data msg))]
              (js/console.log "Worker message: " (pr-str clj))))
          (onerror [err]
            (js/console.error (str "Worker error: " (.-message err)))
            (swap! n-error inc)
            (when (<= @n-error max-error)
              (swap! worker
                     (fn [w]
                       (.terminate @worker)
                       (new-worker)))))]
    (let [w (js/Worker. "worker.js")]
      (set! (.-onerror w) onerror)
      (set! (.-onmessage w) onmsg)
      w)))

(defn ticker []
  (.postMessage @worker
                (blert/encode [:echo [{:hello :piroxy}
                                      "how are you?"
                                      (seq [1.01 2.02 3.03])]])))
(reset! worker (new-worker))
(js/setInterval ticker 5000)
(c/dump)
