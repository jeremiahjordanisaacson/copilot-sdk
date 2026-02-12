;;;; ---------------------------------------------------------------------------
;;;;  Copyright (c) Microsoft Corporation. All rights reserved.
;;;; ---------------------------------------------------------------------------
;;;;
;;;; Copilot CLI SDK Client - Main entry point for the Copilot SDK.
;;;;
;;;; Manages the connection to the Copilot CLI server and provides session
;;;; management capabilities.

(ns copilot.client
  "Main client for interacting with the Copilot CLI.

  The CopilotClient manages the connection to the Copilot CLI server and
  provides methods to create and manage conversation sessions.  It can
  either spawn a CLI server process or connect to an existing server."
  (:require [copilot.json-rpc :as rpc]
            [copilot.session :as session]
            [copilot.sdk-protocol-version :as proto]
            [copilot.types :as types])
  (:import [java.lang Process ProcessBuilder ProcessBuilder$Redirect]
           [java.net Socket]
           [java.io Closeable]))

;; ============================================================================
;; Internal helpers
;; ============================================================================

(defn- parse-cli-url
  "Parse a CLI URL string into {:host h :port p}.
  Supports formats: \"host:port\", \"http://host:port\", or just \"port\"."
  [^String url]
  (let [clean (.replaceAll url "^https?://" "")]
    (if (re-matches #"\d+" clean)
      {:host "localhost" :port (Integer/parseInt clean)}
      (let [parts (.split clean ":")]
        (when (not= 2 (alength parts))
          (throw (ex-info (str "Invalid cliUrl format: " url
                               ". Expected \"host:port\", \"http://host:port\", or \"port\"")
                          {:url url})))
        (let [host (if (empty? (aget parts 0)) "localhost" (aget parts 0))
              port (Integer/parseInt (aget parts 1))]
          (when (or (<= port 0) (> port 65535))
            (throw (ex-info (str "Invalid port in cliUrl: " url) {:url url})))
          {:host host :port port})))))

(defn- build-cli-args
  "Build the CLI argument list from options."
  [opts]
  (let [extra-args  (or (:cli-args opts) [])
        log-level   (or (:log-level opts) "info")
        use-stdio   (if (contains? opts :use-stdio) (:use-stdio opts) true)
        port        (or (:port opts) 0)
        github-token (:github-token opts)
        use-logged-in (if (contains? opts :use-logged-in-user)
                        (:use-logged-in-user opts)
                        (if github-token false true))]
    (cond-> (vec (concat extra-args
                         ["--headless" "--no-auto-update"
                          "--log-level" (name log-level)]))
      use-stdio          (conj "--stdio")
      (and (not use-stdio)
           (pos? port))  (conj "--port" (str port))
      github-token       (conj "--auth-token-env" "COPILOT_SDK_AUTH_TOKEN")
      (not use-logged-in) (conj "--no-auto-login"))))

(defn- spawn-cli-process
  "Spawn the Copilot CLI process. Returns a java.lang.Process."
  [opts]
  (let [cli-path (or (:cli-path opts) "copilot")
        args     (build-cli-args opts)
        cwd      (or (:cwd opts) (System/getProperty "user.dir"))
        env      (:env opts)
        pb       (ProcessBuilder. ^java.util.List (into [cli-path] args))]
    (.directory pb (java.io.File. ^String cwd))
    (.redirectErrorStream pb false)
    ;; Redirect stderr to inherit so logs are visible
    (.redirectError pb ProcessBuilder$Redirect/INHERIT)
    ;; Set environment
    (let [pb-env (.environment pb)]
      ;; Remove NODE_DEBUG to avoid polluting stdout
      (.remove pb-env "NODE_DEBUG")
      ;; Add custom env vars
      (when env
        (doseq [[k v] env]
          (.put pb-env k v)))
      ;; Add auth token to environment if provided
      (when-let [token (:github-token opts)]
        (.put pb-env "COPILOT_SDK_AUTH_TOKEN" token)))
    (.start pb)))

;; ============================================================================
;; Tool result normalisation
;; ============================================================================

(defn- tool-result-object?
  "Check if a value looks like a ToolResultObject (duck-type check)."
  [v]
  (and (map? v)
       (contains? v :textResultForLlm)
       (string? (:textResultForLlm v))
       (contains? v :resultType)))

(defn- normalize-tool-result
  "Normalize any value to a ToolResultObject map."
  [result]
  (cond
    (nil? result)
    {:textResultForLlm "Tool returned no result"
     :resultType       "failure"
     :error            "tool returned no result"
     :toolTelemetry    {}}

    (tool-result-object? result)
    result

    (string? result)
    {:textResultForLlm result
     :resultType       "success"
     :toolTelemetry    {}}

    :else
    {:textResultForLlm (pr-str result)
     :resultType       "success"
     :toolTelemetry    {}}))

;; ============================================================================
;; CopilotClient
;; ============================================================================

(defn- make-session-create-params
  "Build the params map for session.create or session.resume."
  [config]
  (let [{:keys [model session-id reasoning-effort tools system-message
                available-tools excluded-tools provider on-permission-request
                on-user-input-request hooks working-directory streaming
                mcp-servers custom-agents config-dir skill-directories
                disabled-skills infinite-sessions disable-resume]} config]
    (cond-> {}
      model               (assoc :model model)
      session-id          (assoc :sessionId session-id)
      reasoning-effort    (assoc :reasoningEffort (name reasoning-effort))
      tools               (assoc :tools (mapv (fn [t]
                                                {:name        (:name t)
                                                 :description (:description t)
                                                 :parameters  (:parameters t)})
                                              tools))
      system-message      (assoc :systemMessage system-message)
      available-tools     (assoc :availableTools available-tools)
      excluded-tools      (assoc :excludedTools excluded-tools)
      provider            (assoc :provider provider)
      on-permission-request   (assoc :requestPermission true)
      on-user-input-request   (assoc :requestUserInput true)
      (and hooks (some val (vals hooks))) (assoc :hooks true)
      working-directory   (assoc :workingDirectory working-directory)
      (some? streaming)   (assoc :streaming streaming)
      mcp-servers         (assoc :mcpServers mcp-servers)
      custom-agents       (assoc :customAgents custom-agents)
      config-dir          (assoc :configDir config-dir)
      skill-directories   (assoc :skillDirectories skill-directories)
      disabled-skills     (assoc :disabledSkills disabled-skills)
      infinite-sessions   (assoc :infiniteSessions infinite-sessions)
      (some? disable-resume) (assoc :disableResume disable-resume))))

(defn create-client
  "Create a new CopilotClient.

  Returns a client map (atom-backed) that manages the CLI process, JSON-RPC
  connection, and sessions.

  Options (all optional):
    :cli-path, :cli-args, :cwd, :port, :use-stdio, :cli-url,
    :log-level, :auto-start, :auto-restart, :env,
    :github-token, :use-logged-in-user

  See `copilot.types/client-options` for full documentation."
  [& {:as opts}]
  (let [opts (or opts {})]
    ;; Validate mutually exclusive options
    (when (and (:cli-url opts)
               (or (true? (:use-stdio opts)) (:cli-path opts)))
      (throw (ex-info "cliUrl is mutually exclusive with useStdio and cliPath"
                      {:opts opts})))
    (when (and (:cli-url opts)
               (or (:github-token opts) (contains? opts :use-logged-in-user)))
      (throw (ex-info "githubToken and useLoggedInUser cannot be used with cliUrl"
                      {:opts opts})))

    (let [external? (boolean (:cli-url opts))
          parsed    (when external? (parse-cli-url (:cli-url opts)))]
      (atom {:options      opts
             :state        :disconnected    ;; :disconnected :connecting :connected :error
             :process      nil              ;; java.lang.Process
             :rpc-client   nil              ;; copilot.json-rpc/JsonRpcClient
             :socket       nil              ;; java.net.Socket (TCP mode only)
             :sessions     {}               ;; session-id -> session atom
             :models-cache nil              ;; cached model list
             :external?    external?
             :host         (or (:host parsed) "localhost")
             :port         (:port parsed)
             :lifecycle-handlers (atom #{})}))))

;; ============================================================================
;; Connection management
;; ============================================================================

(defn- attach-connection-handlers!
  "Wire up notification and request handlers on the RPC client."
  [client-atom rpc-client]
  ;; Session event notifications
  (rpc/set-notification-handler!
   rpc-client
   (fn [method params]
     (let [state @client-atom]
       (case method
         "session.event"
         (when-let [session-id (:sessionId params)]
           (when-let [session-atom (get-in state [:sessions session-id])]
             (session/dispatch-event! session-atom (:event params))))

         "session.lifecycle"
         (let [event (types/session-lifecycle-event params)
               handlers @(:lifecycle-handlers state)]
           (doseq [h handlers]
             (try (h event) (catch Exception _))))

         ;; Unknown notification - ignore
         nil))))

  ;; Tool call requests from server
  (rpc/set-request-handler!
   rpc-client "tool.call"
   (fn [params]
     (let [session-id  (:sessionId params)
           tool-name   (:toolName params)
           tool-call-id (:toolCallId params)
           arguments   (:arguments params)
           state       @client-atom
           session-atom (get-in state [:sessions session-id])]
       (if-not session-atom
         {:result {:textResultForLlm (str "Unknown session " session-id)
                   :resultType       "failure"
                   :toolTelemetry    {}}}
         (let [handler (session/get-tool-handler session-atom tool-name)]
           (if-not handler
             {:result {:textResultForLlm (str "Tool '" tool-name "' is not supported by this client instance.")
                       :resultType       "failure"
                       :error            (str "tool '" tool-name "' not supported")
                       :toolTelemetry    {}}}
             (try
               (let [invocation (types/tool-invocation session-id tool-call-id tool-name arguments)
                     result     (handler arguments invocation)]
                 {:result (normalize-tool-result result)})
               (catch Exception e
                 {:result {:textResultForLlm "Invoking this tool produced an error. Detailed information is not available."
                           :resultType       "failure"
                           :error            (.getMessage e)
                           :toolTelemetry    {}}}))))))))

  ;; Permission requests from server
  (rpc/set-request-handler!
   rpc-client "permission.request"
   (fn [params]
     (let [session-id (:sessionId params)
           state      @client-atom
           session-atom (get-in state [:sessions session-id])]
       (if-not session-atom
         {:result {:kind "denied-no-approval-rule-and-could-not-request-from-user"}}
         (try
           (let [result (session/handle-permission-request! session-atom (:permissionRequest params))]
             {:result result})
           (catch Exception _
             {:result {:kind "denied-no-approval-rule-and-could-not-request-from-user"}}))))))

  ;; User input requests from server
  (rpc/set-request-handler!
   rpc-client "userInput.request"
   (fn [params]
     (let [session-id (:sessionId params)
           state      @client-atom
           session-atom (get-in state [:sessions session-id])]
       (if-not session-atom
         (throw (ex-info "Session not found" {:session-id session-id}))
         (session/handle-user-input-request!
          session-atom
          {:question      (:question params)
           :choices       (:choices params)
           :allowFreeform (:allowFreeform params)})))))

  ;; Hooks invoke requests from server
  (rpc/set-request-handler!
   rpc-client "hooks.invoke"
   (fn [params]
     (let [session-id (:sessionId params)
           hook-type  (:hookType params)
           input      (:input params)
           state      @client-atom
           session-atom (get-in state [:sessions session-id])]
       (if-not session-atom
         {:output nil}
         (let [output (session/handle-hooks-invoke! session-atom hook-type input)]
           {:output output}))))))

(defn- connect-stdio!
  "Connect to CLI via stdio pipes."
  [client-atom ^Process process]
  (let [in-stream  (.getInputStream process)
        out-stream (.getOutputStream process)
        rpc-client (rpc/create-client in-stream out-stream)]
    (attach-connection-handlers! client-atom rpc-client)
    (rpc/start! rpc-client)
    (swap! client-atom assoc :rpc-client rpc-client)))

(defn- connect-tcp!
  "Connect to CLI via TCP."
  [client-atom ^String host ^long port]
  (let [{:keys [client socket]} (rpc/create-tcp-client host port)]
    (attach-connection-handlers! client-atom client)
    (rpc/start! client)
    (swap! client-atom assoc :rpc-client client :socket socket)))

(defn- verify-protocol-version!
  "Verify that the server's protocol version matches the SDK's expected version."
  [client-atom]
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "ping" {:message "version-check"})
        server-version (:protocolVersion result)
        expected   (proto/get-sdk-protocol-version)]
    (when (nil? server-version)
      (throw (ex-info (str "SDK protocol version mismatch: SDK expects version " expected
                           ", but server does not report a protocol version. "
                           "Please update your server to ensure compatibility.")
                      {:expected expected})))
    (when (not= server-version expected)
      (throw (ex-info (str "SDK protocol version mismatch: SDK expects version " expected
                           ", but server reports version " server-version ". "
                           "Please update your SDK or server to ensure compatibility.")
                      {:expected expected :actual server-version})))))

;; ============================================================================
;; Public API
;; ============================================================================

(defn start!
  "Start the CLI server and establish a connection.

  If the client was created with :cli-url, only establishes the connection.
  Otherwise spawns the CLI server process and connects via stdio or TCP.

  This is called automatically when creating a session if :auto-start is
  true (the default)."
  [client-atom]
  (when-not (= :connected (:state @client-atom))
    (let [state @client-atom]
      (swap! client-atom assoc :state :connecting)
      (try
        (if (:external? state)
          ;; External server - just connect
          (connect-tcp! client-atom (:host state) (:port state))
          ;; Spawn CLI process
          (let [process (spawn-cli-process (:options state))
                use-stdio (if (contains? (:options state) :use-stdio)
                            (:use-stdio (:options state))
                            true)]
            (swap! client-atom assoc :process process)
            (if use-stdio
              (connect-stdio! client-atom process)
              ;; TCP mode: use the configured port
              (let [port (or (:port (:options state)) 0)]
                (when (zero? port)
                  (throw (ex-info "TCP mode requires a port to be specified" {})))
                (Thread/sleep 2000) ;; Wait for server to start
                (connect-tcp! client-atom "localhost" port)))))
        ;; Verify protocol version
        (verify-protocol-version! client-atom)
        (swap! client-atom assoc :state :connected)
        (catch Exception e
          (swap! client-atom assoc :state :error)
          (throw e))))))

(defn stop!
  "Stop the CLI server and close all active sessions.

  Returns a vector of error messages encountered during cleanup."
  [client-atom]
  (let [errors (atom [])
        state  @client-atom]
    ;; Destroy all sessions
    (doseq [[session-id session-atom] (:sessions state)]
      (try
        (session/destroy! session-atom)
        (catch Exception e
          (swap! errors conj (str "Failed to destroy session " session-id ": " (.getMessage e))))))
    (swap! client-atom assoc :sessions {})

    ;; Stop RPC client
    (when-let [rpc (:rpc-client state)]
      (try
        (rpc/stop! rpc)
        (catch Exception e
          (swap! errors conj (str "Failed to stop RPC client: " (.getMessage e))))))
    (swap! client-atom assoc :rpc-client nil)

    ;; Clear models cache
    (swap! client-atom assoc :models-cache nil)

    ;; Close TCP socket if present
    (when-let [^Socket socket (:socket state)]
      (try
        (.close socket)
        (catch Exception e
          (swap! errors conj (str "Failed to close socket: " (.getMessage e))))))
    (swap! client-atom assoc :socket nil)

    ;; Kill CLI process (only if we spawned it)
    (when (and (not (:external? state)) (:process state))
      (try
        (.destroyForcibly ^Process (:process state))
        (catch Exception e
          (swap! errors conj (str "Failed to kill CLI process: " (.getMessage e))))))
    (swap! client-atom assoc :process nil :state :disconnected :port nil)

    @errors))

(defn force-stop!
  "Forcefully stop the CLI server without graceful cleanup."
  [client-atom]
  (swap! client-atom assoc :sessions {})
  (when-let [rpc (:rpc-client @client-atom)]
    (try (rpc/stop! rpc) (catch Exception _)))
  (swap! client-atom assoc :rpc-client nil :models-cache nil)
  (when-let [^Socket socket (:socket @client-atom)]
    (try (.close socket) (catch Exception _)))
  (swap! client-atom assoc :socket nil)
  (when-let [^Process process (:process @client-atom)]
    (when-not (:external? @client-atom)
      (try (.destroyForcibly process) (catch Exception _))))
  (swap! client-atom assoc :process nil :state :disconnected :port nil)
  nil)

(defn- ensure-connected!
  "Ensure the client is connected, auto-starting if configured."
  [client-atom]
  (when-not (= :connected (:state @client-atom))
    (let [auto-start (if (contains? (:options @client-atom) :auto-start)
                       (:auto-start (:options @client-atom))
                       true)]
      (if auto-start
        (start! client-atom)
        (throw (ex-info "Client not connected. Call start! first." {}))))))

(defn create-session!
  "Create a new conversation session with the Copilot CLI.

  `config` - session configuration map (see `copilot.types/session-config`)

  Returns a session atom that can be used with `copilot.session` functions."
  [client-atom & {:as config}]
  (let [config (or config {})]
    (ensure-connected! client-atom)
    (let [rpc-client (:rpc-client @client-atom)
          params     (make-session-create-params config)
          response   (rpc/request! rpc-client "session.create" params)
          session-id (:sessionId response)
          workspace  (:workspacePath response)
          sess       (session/create-session session-id rpc-client workspace)]
      ;; Register tools
      (when-let [tools (:tools config)]
        (session/register-tools! sess tools))
      ;; Register permission handler
      (when-let [h (:on-permission-request config)]
        (session/register-permission-handler! sess h))
      ;; Register user input handler
      (when-let [h (:on-user-input-request config)]
        (session/register-user-input-handler! sess h))
      ;; Register hooks
      (when-let [h (:hooks config)]
        (session/register-hooks! sess h))
      ;; Store session in client
      (swap! client-atom assoc-in [:sessions session-id] sess)
      sess)))

(defn resume-session!
  "Resume an existing conversation session.

  `session-id` - the ID of the session to resume
  `config`     - optional resume configuration map

  Returns a session atom."
  [client-atom session-id & {:as config}]
  (let [config (or config {})]
    (ensure-connected! client-atom)
    (let [rpc-client (:rpc-client @client-atom)
          params     (-> (make-session-create-params config)
                         (assoc :sessionId session-id))
          response   (rpc/request! rpc-client "session.resume" params)
          resumed-id (:sessionId response)
          workspace  (:workspacePath response)
          sess       (session/create-session resumed-id rpc-client workspace)]
      (when-let [tools (:tools config)]
        (session/register-tools! sess tools))
      (when-let [h (:on-permission-request config)]
        (session/register-permission-handler! sess h))
      (when-let [h (:on-user-input-request config)]
        (session/register-user-input-handler! sess h))
      (when-let [h (:hooks config)]
        (session/register-hooks! sess h))
      (swap! client-atom assoc-in [:sessions resumed-id] sess)
      sess)))

(defn get-state
  "Get the current connection state: :disconnected :connecting :connected :error"
  [client-atom]
  (:state @client-atom))

(defn ping!
  "Send a ping request to the server.

  Returns {:message ... :timestamp ... :protocol-version ...}"
  [client-atom & {:keys [message]}]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "ping" {:message (or message "")})]
    (types/ping-response result)))

(defn get-status!
  "Get CLI status including version and protocol information."
  [client-atom]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "status.get" {})]
    (types/get-status-response result)))

(defn get-auth-status!
  "Get current authentication status."
  [client-atom]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "auth.getStatus" {})]
    (types/get-auth-status-response result)))

(defn list-models!
  "List available models. Results are cached after the first call.

  Returns a vector of model-info maps."
  [client-atom]
  (ensure-connected! client-atom)
  (if-let [cached (:models-cache @client-atom)]
    cached
    (let [rpc-client (:rpc-client @client-atom)
          result     (rpc/request! rpc-client "models.list" {})
          models     (mapv types/model-info (:models result))]
      (swap! client-atom assoc :models-cache models)
      models)))

(defn get-last-session-id!
  "Get the ID of the most recently updated session."
  [client-atom]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "session.getLastId" {})]
    (:sessionId result)))

(defn delete-session!
  "Delete a session and its data from disk."
  [client-atom session-id]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "session.delete" {:sessionId session-id})]
    (when-not (:success result)
      (throw (ex-info (str "Failed to delete session " session-id ": "
                           (or (:error result) "Unknown error"))
                      {:session-id session-id})))
    (swap! client-atom update :sessions dissoc session-id)
    nil))

(defn list-sessions!
  "List all available sessions.

  Returns a vector of session-metadata maps."
  [client-atom]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "session.list" {})]
    (mapv types/session-metadata (:sessions result))))

(defn get-foreground-session-id!
  "Get the foreground session ID (TUI+server mode only)."
  [client-atom]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "session.getForeground" {})]
    (:sessionId result)))

(defn set-foreground-session-id!
  "Set the foreground session (TUI+server mode only)."
  [client-atom session-id]
  (ensure-connected! client-atom)
  (let [rpc-client (:rpc-client @client-atom)
        result     (rpc/request! rpc-client "session.setForeground"
                                 {:sessionId session-id})]
    (when-not (:success result)
      (throw (ex-info (or (:error result) "Failed to set foreground session")
                      {:session-id session-id})))
    nil))

(defn on-lifecycle!
  "Subscribe to session lifecycle events.

  `handler` - (fn [event]) where event is a session-lifecycle-event map.
  Returns a zero-arg function that unsubscribes the handler."
  [client-atom handler]
  (let [handlers-atom (:lifecycle-handlers @client-atom)]
    (swap! handlers-atom conj handler)
    (fn [] (swap! handlers-atom disj handler))))

(defn on-lifecycle-type!
  "Subscribe to a specific session lifecycle event type.

  `event-type` - string like \"session.created\", \"session.deleted\", etc.
  `handler`    - (fn [event])
  Returns an unsubscribe function."
  [client-atom event-type handler]
  (on-lifecycle! client-atom
                 (fn [event]
                   (when (= event-type (:type event))
                     (handler event)))))
