;;;; ---------------------------------------------------------------------------
;;;;  Copyright (c) Microsoft Corporation. All rights reserved.
;;;; ---------------------------------------------------------------------------
;;;;
;;;; Copilot Session - represents a single conversation session with the
;;;; Copilot CLI.

(ns copilot.session
  "A CopilotSession maintains conversation state, handles events, and manages
  tool execution.  Sessions are created via `copilot.client/create-session!`
  or resumed via `copilot.client/resume-session!`."
  (:require [copilot.json-rpc :as rpc]))

;; ============================================================================
;; Session construction
;; ============================================================================

(defn create-session
  "Create a new session atom.  Internal -- use `copilot.client/create-session!`.

  Returns an atom containing the session state map."
  [session-id rpc-client workspace-path]
  (atom {:session-id         session-id
         :rpc-client         rpc-client
         :workspace-path     workspace-path
         :event-handlers     #{}      ;; set of (fn [event])
         :typed-handlers     {}       ;; {event-type #{(fn [event])}}
         :tool-handlers      {}       ;; {tool-name handler-fn}
         :permission-handler nil      ;; (fn [request invocation])
         :user-input-handler nil      ;; (fn [request invocation])
         :hooks              nil}))   ;; session-hooks map

;; ============================================================================
;; Event subscription
;; ============================================================================

(defn on!
  "Subscribe to all session events.

  `handler` - (fn [event]) called for every event.
  Returns a zero-arg unsubscribe function."
  [session-atom handler]
  (swap! session-atom update :event-handlers conj handler)
  (fn [] (swap! session-atom update :event-handlers disj handler)))

(defn on-type!
  "Subscribe to a specific event type.

  `event-type` - string, e.g. \"assistant.message\", \"session.idle\"
  `handler`    - (fn [event])
  Returns a zero-arg unsubscribe function."
  [session-atom event-type handler]
  (swap! session-atom update-in [:typed-handlers event-type]
         (fnil conj #{}) handler)
  (fn []
    (swap! session-atom update-in [:typed-handlers event-type] disj handler)))

(defn dispatch-event!
  "Dispatch an event to all registered handlers.  Internal."
  [session-atom event]
  (let [state @session-atom
        event-type (:type event)]
    ;; Typed handlers
    (when-let [handlers (get-in state [:typed-handlers event-type])]
      (doseq [h handlers]
        (try (h event) (catch Exception _))))
    ;; Wildcard handlers
    (doseq [h (:event-handlers state)]
      (try (h event) (catch Exception _)))))

;; ============================================================================
;; Tool registration
;; ============================================================================

(defn register-tools!
  "Register tool handlers for this session.

  `tools` - vector of tool maps (see `copilot.types/tool`)"
  [session-atom tools]
  (swap! session-atom assoc :tool-handlers
         (into {} (map (fn [t] [(:name t) (:handler t)])) tools)))

(defn get-tool-handler
  "Get the handler function for a named tool, or nil."
  [session-atom tool-name]
  (get-in @session-atom [:tool-handlers tool-name]))

;; ============================================================================
;; Permission handling
;; ============================================================================

(defn register-permission-handler!
  "Register a permission handler.

  `handler` - (fn [request invocation] -> permission-result-map)"
  [session-atom handler]
  (swap! session-atom assoc :permission-handler handler))

(defn handle-permission-request!
  "Handle an incoming permission request.  Internal."
  [session-atom request]
  (let [handler (:permission-handler @session-atom)]
    (if-not handler
      {:kind "denied-no-approval-rule-and-could-not-request-from-user"}
      (try
        (handler request {:session-id (:session-id @session-atom)})
        (catch Exception _
          {:kind "denied-no-approval-rule-and-could-not-request-from-user"})))))

;; ============================================================================
;; User input handling
;; ============================================================================

(defn register-user-input-handler!
  "Register a user input handler.

  `handler` - (fn [request invocation] -> {:answer str :wasFreeform bool})"
  [session-atom handler]
  (swap! session-atom assoc :user-input-handler handler))

(defn handle-user-input-request!
  "Handle an incoming user input request.  Internal."
  [session-atom request]
  (let [handler (:user-input-handler @session-atom)]
    (if-not handler
      (throw (ex-info "User input requested but no handler registered" {}))
      (handler request {:session-id (:session-id @session-atom)}))))

;; ============================================================================
;; Hooks handling
;; ============================================================================

(defn register-hooks!
  "Register session hooks.

  `hooks` - map with optional keys:
    :on-pre-tool-use, :on-post-tool-use, :on-user-prompt-submitted,
    :on-session-start, :on-session-end, :on-error-occurred"
  [session-atom hooks]
  (swap! session-atom assoc :hooks hooks))

(defn handle-hooks-invoke!
  "Handle an incoming hooks invoke request.  Internal."
  [session-atom hook-type input]
  (let [hooks (:hooks @session-atom)]
    (when hooks
      (let [handler-map {"preToolUse"            :on-pre-tool-use
                         "postToolUse"           :on-post-tool-use
                         "userPromptSubmitted"   :on-user-prompt-submitted
                         "sessionStart"          :on-session-start
                         "sessionEnd"            :on-session-end
                         "errorOccurred"         :on-error-occurred}
            hook-key    (get handler-map hook-type)
            handler     (when hook-key (get hooks hook-key))]
        (when handler
          (try
            (handler input {:session-id (:session-id @session-atom)})
            (catch Exception _ nil)))))))

;; ============================================================================
;; Messaging
;; ============================================================================

(defn send!
  "Send a message to this session.

  `options` - message options map with :prompt and optional :attachments, :mode

  Returns the message ID string."
  [session-atom options]
  (let [state      @session-atom
        rpc-client (:rpc-client state)
        params     {:sessionId   (:session-id state)
                    :prompt      (:prompt options)
                    :attachments (:attachments options)
                    :mode        (:mode options)}
        response   (rpc/request! rpc-client "session.send" params)]
    (:messageId response)))

(defn send-and-wait!
  "Send a message and wait until the session becomes idle.

  Returns the last assistant.message event, or nil if none received.

  `options`    - message options map with :prompt
  `timeout-ms` - timeout in milliseconds (default 60000)"
  ([session-atom options]
   (send-and-wait! session-atom options 60000))
  ([session-atom options timeout-ms]
   (let [idle-promise     (promise)
         error-promise    (promise)
         last-msg         (atom nil)
         ;; Subscribe BEFORE sending to avoid race
         unsub (on! session-atom
                    (fn [event]
                      (case (:type event)
                        "assistant.message"
                        (reset! last-msg event)

                        "session.idle"
                        (deliver idle-promise true)

                        "session.error"
                        (deliver error-promise
                                 (ex-info (get-in event [:data :message] "Session error")
                                          {:event event}))
                        ;; default
                        nil)))]
     (try
       (send! session-atom options)
       ;; Wait for idle or error or timeout
       (let [result (deref idle-promise timeout-ms ::timeout)]
         (cond
           (realized? error-promise)
           (throw @error-promise)

           (= result ::timeout)
           (throw (ex-info (str "Timeout after " timeout-ms "ms waiting for session.idle")
                           {:timeout-ms timeout-ms}))

           :else
           @last-msg))
       (finally
         (unsub))))))

;; ============================================================================
;; Session management
;; ============================================================================

(defn session-id
  "Get the session ID."
  [session-atom]
  (:session-id @session-atom))

(defn workspace-path
  "Get the workspace path (when infinite sessions are enabled), or nil."
  [session-atom]
  (:workspace-path @session-atom))

(defn get-messages!
  "Retrieve all events/messages from this session's history."
  [session-atom]
  (let [state      @session-atom
        rpc-client (:rpc-client state)
        response   (rpc/request! rpc-client "session.getMessages"
                                 {:sessionId (:session-id state)})]
    (:events response)))

(defn destroy!
  "Destroy this session and release resources.

  After calling this, the session can no longer be used."
  [session-atom]
  (let [state @session-atom
        rpc-client (:rpc-client state)]
    (rpc/request! rpc-client "session.destroy"
                  {:sessionId (:session-id state)})
    (swap! session-atom assoc
           :event-handlers #{}
           :typed-handlers {}
           :tool-handlers {}
           :permission-handler nil
           :user-input-handler nil
           :hooks nil)
    nil))

(defn abort!
  "Abort the currently processing message in this session."
  [session-atom]
  (let [state      @session-atom
        rpc-client (:rpc-client state)]
    (rpc/request! rpc-client "session.abort"
                  {:sessionId (:session-id state)})
    nil))
