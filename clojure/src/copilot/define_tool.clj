;;;; ---------------------------------------------------------------------------
;;;;  Copyright (c) Microsoft Corporation. All rights reserved.
;;;; ---------------------------------------------------------------------------
;;;;
;;;; Helper macro and function for defining tools idiomatically in Clojure.

(ns copilot.define-tool
  "Idiomatic helpers for defining Copilot tools.

  Provides `define-tool` (function) and `deftool` (macro) for concise
  tool definitions with automatic result normalisation."
  (:require [cheshire.core :as json]
            [copilot.types :as types]))

;; ============================================================================
;; Result normalisation
;; ============================================================================

(defn- normalize-result
  "Convert any return value to a ToolResult map.

  - nil            -> empty success
  - String         -> success with text
  - ToolResultObject (map with :textResultForLlm + :resultType) -> pass through
  - Anything else  -> JSON-serialised success"
  [result]
  (cond
    (nil? result)
    {:textResultForLlm ""
     :resultType       "success"
     :toolTelemetry    {}}

    ;; Already a ToolResultObject
    (and (map? result)
         (contains? result :textResultForLlm)
         (contains? result :resultType))
    result

    ;; Plain string
    (string? result)
    {:textResultForLlm result
     :resultType       "success"
     :toolTelemetry    {}}

    ;; Everything else -> JSON
    :else
    {:textResultForLlm (json/generate-string result)
     :resultType       "success"
     :toolTelemetry    {}}))

;; ============================================================================
;; define-tool function
;; ============================================================================

(defn define-tool
  "Define a tool with automatic result normalisation.

  The handler function receives `(args invocation)` where:
    - `args`       is the parsed arguments map from the LLM
    - `invocation` is a map with :session-id :tool-call-id :tool-name :arguments

  The handler may return:
    - A string (wrapped as success)
    - A ToolResultObject map (passed through)
    - Any other value (JSON-serialised as success)
    - nil (empty success)

  Exceptions in the handler are caught and returned as failure results with
  the error detail hidden from the LLM.

  Parameters:
    `name`        - tool name string
    `description` - description shown to the LLM
    `parameters`  - JSON Schema map for the tool's parameters (or nil)
    `handler-fn`  - (fn [args invocation]) -> any

  Returns a tool map suitable for `copilot.client/create-session!` :tools."
  ([name description handler-fn]
   (define-tool name description nil handler-fn))
  ([name description parameters handler-fn]
   {:name        name
    :description (or description "")
    :parameters  parameters
    :handler     (fn [args invocation]
                   (try
                     (normalize-result (handler-fn args invocation))
                     (catch Exception e
                       {:textResultForLlm "Invoking this tool produced an error. Detailed information is not available."
                        :resultType       "failure"
                        :error            (.getMessage e)
                        :toolTelemetry    {}})))}))

;; ============================================================================
;; deftool macro
;; ============================================================================

(defmacro deftool
  "Define a tool and bind it to a var.

  Usage:

    (deftool lookup-fact
      \"Returns a fun fact about a given topic.\"
      {:type       \"object\"
       :properties {:topic {:type \"string\"
                            :description \"Topic to look up\"}}
       :required   [\"topic\"]}
      [args invocation]
      (get facts (get args :topic) \"No fact found.\"))

  Expands to a `def` binding to the result of `define-tool`.

  The body has access to the bindings specified in the parameter vector.
  The first binding receives the arguments map, the second (optional)
  receives the invocation context map."
  {:arglists '([name docstring schema [args-binding invocation-binding] & body]
               [name docstring [args-binding invocation-binding] & body])}
  [var-name description & more]
  (let [[schema bindings & body]
        (if (map? (first more))
          more
          (cons nil more))
        tool-name (clojure.core/name var-name)
        args-sym  (first bindings)
        inv-sym   (or (second bindings) (gensym "inv"))]
    `(def ~var-name
       (define-tool ~tool-name
                    ~description
                    ~schema
                    (fn [~args-sym ~inv-sym]
                      ~@body)))))
