(ns piroxy.component)

(defmacro defrc [sym & methods]
  (letfn [(kv [meth]
            (prn meth)
            (let [sym (first meth)
                  args (second meth)
                  body (nnext meth)]
              [(name sym) `(fn* ~args ~@body)]))]
    `(def ~sym
       (create-react-class
        (js-obj ~@(apply concat (map kv methods)))))))
