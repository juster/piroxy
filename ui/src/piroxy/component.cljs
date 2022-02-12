(ns piroxy.component
  [require '[react :as r]])

(defn useState [init]
  (let [state (r/useState 0)
        v (aget state 0)
        f (aget state 1)]
    [v f]))

(defn elm
  ([tag]
   (r/createElement tag))
  ([tag body]
   (r/createElement tag nil body))
  ([tag props body]
   (r/createElement tag props body)))

(defn Counter [counterState]
  (let [[counter _] counterState]
    (elm "div"
         (elm "p"
              (format "Received %d messages." counter)))))
