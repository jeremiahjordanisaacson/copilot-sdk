;;;; ---------------------------------------------------------------------------
;;;;  Copyright (c) Microsoft Corporation. All rights reserved.
;;;; ---------------------------------------------------------------------------
;;;;
;;;; Basic example demonstrating the Copilot Clojure SDK.
;;;;
;;;; Run with:  clj -M:dev -m basic-example

(ns basic-example
  "Full working example showing client creation, tool definition,
  event subscription, and send-and-wait."
  (:require [copilot.client :as client]
            [copilot.session :as session]
            [copilot.define-tool :refer [deftool define-tool]]))

;; ============================================================================
;; 1. Define custom tools
;; ============================================================================

;; Option A: Using the deftool macro for concise definitions
(def facts
  {"javascript" "JavaScript was created in 10 days by Brendan Eich in 1995."
   "node"       "Node.js lets you run JavaScript outside the browser using the V8 engine."
   "clojure"    "Clojure was created by Rich Hickey and first released in 2007."})

(deftool lookup-fact
  "Returns a fun fact about a given topic."
  {:type       "object"
   :properties {:topic {:type        "string"
                        :description "Topic to look up (e.g. 'javascript', 'node', 'clojure')"}}
   :required   ["topic"]}
  [args _invocation]
  (let [topic (clojure.string/lower-case (or (:topic args) ""))]
    (get facts topic (str "No fact stored for " topic "."))))

;; Option B: Using define-tool function directly
(def get-time-tool
  (define-tool "get_current_time"
               "Returns the current server time."
               nil  ;; no parameters
               (fn [_args _invocation]
                 (str "Current time: " (java.time.Instant/now)))))

;; ============================================================================
;; 2. Main example flow
;; ============================================================================

(defn -main
  [& _args]
  (println "Starting Copilot SDK Example\n")

  ;; Create client - will auto-start CLI server
  (let [client (client/create-client :log-level "info")]
    (try
      ;; Create a session with our custom tools
      (let [sess (client/create-session! client
                   :tools [lookup-fact get-time-tool])]
        (println (str "Session created: " (session/session-id sess) "\n"))

        ;; Subscribe to all events
        (let [unsub (session/on! sess
                      (fn [event]
                        (println (str "  Event [" (:type event) "]: "
                                      (pr-str (:data event))))))]

          ;; Send a simple message and wait for response
          (println "Sending message: Tell me 2+2")
          (let [result (session/send-and-wait! sess {:prompt "Tell me 2+2"})]
            (println (str "\nResponse: "
                          (get-in result [:data :content])
                          "\n")))

          ;; Send a message that uses the lookup_fact tool
          (println "Sending message: Use lookup_fact to tell me about 'clojure'")
          (let [result (session/send-and-wait! sess
                         {:prompt "Use lookup_fact to tell me about 'clojure'"})]
            (println (str "\nResponse: "
                          (get-in result [:data :content])
                          "\n")))

          ;; Unsubscribe event handler
          (unsub))

        ;; Clean up session
        (session/destroy! sess))

      ;; Stop the client
      (let [errors (client/stop! client)]
        (when (seq errors)
          (println "Cleanup errors:" errors)))

      (println "Done!")

      (catch Exception e
        (println "Error:" (.getMessage e))
        (.printStackTrace e)
        (client/force-stop! client)))))

;; ============================================================================
;; 3. Advanced example: Permission handler & user input
;; ============================================================================

(comment
  ;; Example with permission handler and user input
  (let [client (client/create-client :log-level "info")]
    (let [sess (client/create-session! client
                 :tools [lookup-fact]
                 :on-permission-request
                 (fn [request _invocation]
                   (println "Permission requested:" (:kind request))
                   ;; Auto-approve all permissions
                   {:kind "approved"})

                 :on-user-input-request
                 (fn [request _invocation]
                   (println "Agent asks:" (:question request))
                   {:answer "yes" :wasFreeform true})

                 :hooks
                 {:on-pre-tool-use
                  (fn [input _invocation]
                    (println "About to run tool:" (:toolName input))
                    {:permissionDecision "allow"})

                  :on-post-tool-use
                  (fn [input _invocation]
                    (println "Tool completed:" (:toolName input))
                    nil)})]

      ;; Subscribe to specific event types
      (session/on-type! sess "assistant.message"
        (fn [event]
          (println "Assistant:" (get-in event [:data :content]))))

      (session/on-type! sess "session.idle"
        (fn [_event]
          (println "Session is idle")))

      (session/send-and-wait! sess {:prompt "Hello, world!"})

      (session/destroy! sess)
      (client/stop! client)))

  ;; Example: Listing models
  (let [client (client/create-client)]
    (client/start! client)
    (let [models (client/list-models! client)]
      (doseq [m models]
        (println (:id m) "-" (:name m))))
    (client/stop! client))

  ;; Example: Listing and resuming sessions
  (let [client (client/create-client)]
    (client/start! client)
    (let [sessions (client/list-sessions! client)]
      (doseq [s sessions]
        (println (:session-id s) "-" (:summary s)))
      (when-let [last-id (client/get-last-session-id! client)]
        (let [sess (client/resume-session! client last-id)]
          (session/send-and-wait! sess {:prompt "Continue where we left off"})
          (session/destroy! sess))))
    (client/stop! client))
  )
