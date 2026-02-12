;;;; ---------------------------------------------------------------------------
;;;;  Copyright (c) Microsoft Corporation. All rights reserved.
;;;; ---------------------------------------------------------------------------
;;;;
;;;; Type definitions for the Copilot SDK (Clojure).
;;;;
;;;; In idiomatic Clojure we represent most "types" as plain maps with
;;;; well-known keyword keys.  This namespace documents the canonical shapes,
;;;; provides constructor helpers, and defines the small number of records
;;;; that benefit from positional construction.

(ns copilot.types
  "Canonical data shapes used throughout the Copilot Clojure SDK.

  All maps use kebab-case keywords internally.  Conversion to/from
  camelCase JSON happens at the transport boundary (see copilot.json-rpc).")

;; ============================================================================
;; Tool types
;; ============================================================================

(defn tool-result
  "Construct a normalised tool result map.

  `text`        - string result for the LLM
  `result-type` - one of :success :failure :rejected :denied
  `opts`        - optional map of :error :session-log :tool-telemetry
                  :binary-results-for-llm"
  ([text result-type]
   (tool-result text result-type nil))
  ([text result-type opts]
   (merge {:textResultForLlm text
           :resultType       (name result-type)
           :toolTelemetry    {}}
          (when-let [e (:error opts)]             {:error e})
          (when-let [s (:session-log opts)]       {:sessionLog s})
          (when-let [t (:tool-telemetry opts)]    {:toolTelemetry t})
          (when-let [b (:binary-results-for-llm opts)] {:binaryResultsForLlm b}))))

(defn tool-binary-result
  "Construct a binary result entry.

  `data`      - base64-encoded string
  `mime-type` - MIME type string
  `type`      - result type string
  `desc`      - optional description"
  ([data mime-type type]
   (tool-binary-result data mime-type type nil))
  ([data mime-type type desc]
   (cond-> {:data data :mimeType mime-type :type type}
     desc (assoc :description desc))))

(defn tool
  "Construct a tool definition.

  `name`        - tool name string
  `description` - description for the LLM
  `parameters`  - JSON Schema map (or nil)
  `handler`     - (fn [args invocation] ...) -> any  (may return a promise)"
  [name description parameters handler]
  {:name        name
   :description description
   :parameters  parameters
   :handler     handler})

(defn tool-invocation
  "Construct a tool invocation context map."
  [session-id tool-call-id tool-name arguments]
  {:session-id   session-id
   :tool-call-id tool-call-id
   :tool-name    tool-name
   :arguments    arguments})

;; ============================================================================
;; Session configuration
;; ============================================================================

(defn session-config
  "Create a session configuration map.  All keys are optional.

  Recognised keys (kebab-case):
    :session-id :model :reasoning-effort :config-dir
    :tools :system-message :available-tools :excluded-tools
    :provider :on-permission-request :on-user-input-request :hooks
    :working-directory :streaming :mcp-servers :custom-agents
    :skill-directories :disabled-skills :infinite-sessions"
  [& {:as opts}]
  (or opts {}))

(defn resume-session-config
  "Create a resume-session configuration map.  Accepts the same keys as
  `session-config` plus :disable-resume."
  [& {:as opts}]
  (or opts {}))

;; ============================================================================
;; System message configuration
;; ============================================================================

(defn system-message-append
  "Append-mode system message (default). Content is appended after SDK sections."
  ([] {:mode "append"})
  ([content] {:mode "append" :content content}))

(defn system-message-replace
  "Replace-mode system message. Caller provides entire system message."
  [content]
  {:mode "replace" :content content})

;; ============================================================================
;; Permission types
;; ============================================================================

(defn permission-request
  "Construct a permission request map.
  `kind` is one of :shell :write :mcp :read :url."
  [kind & {:as extra}]
  (merge {:kind (name kind)} extra))

(defn permission-result
  "Construct a permission result map.
  `kind` is one of :approved :denied-by-rules
   :denied-no-approval-rule-and-could-not-request-from-user
   :denied-interactively-by-user"
  [kind & {:as extra}]
  (merge {:kind (name kind)} extra))

;; ============================================================================
;; User input types
;; ============================================================================

(defn user-input-request
  "Construct a user input request.
  `question` - string
  Optional: :choices (vec of strings), :allow-freeform (bool)"
  [question & {:as opts}]
  (merge {:question question}
         (when-let [c (:choices opts)]        {:choices c})
         (when-let [a (:allow-freeform opts)] {:allowFreeform a})))

(defn user-input-response
  "Construct a user input response.
  `answer`       - string
  `was-freeform` - boolean"
  [answer was-freeform]
  {:answer answer :wasFreeform was-freeform})

;; ============================================================================
;; Provider configuration
;; ============================================================================

(defn provider-config
  "Create a provider configuration map for BYOK (Bring Your Own Key).

  Required: :base-url
  Optional: :type (:openai :azure :anthropic), :wire-api, :api-key,
            :bearer-token, :azure {:api-version ...}"
  [& {:as opts}]
  (let [{:keys [base-url type wire-api api-key bearer-token azure]} opts]
    (cond-> {:baseUrl base-url}
      type         (assoc :type (name type))
      wire-api     (assoc :wireApi (name wire-api))
      api-key      (assoc :apiKey api-key)
      bearer-token (assoc :bearerToken bearer-token)
      azure        (assoc :azure azure))))

;; ============================================================================
;; MCP server configuration
;; ============================================================================

(defn mcp-local-server-config
  "Create a local/stdio MCP server configuration.

  `command` - command string
  `args`    - vector of argument strings
  `tools`   - vector of tool name strings (or [\"*\"] for all)
  Optional: :type :timeout :env :cwd"
  [command args tools & {:as opts}]
  (cond-> {:command command :args args :tools tools}
    (:type opts)    (assoc :type (name (:type opts)))
    (:timeout opts) (assoc :timeout (:timeout opts))
    (:env opts)     (assoc :env (:env opts))
    (:cwd opts)     (assoc :cwd (:cwd opts))))

(defn mcp-remote-server-config
  "Create a remote MCP server configuration.

  `type`  - :http or :sse
  `url`   - remote server URL
  `tools` - vector of tool name strings
  Optional: :timeout :headers"
  [type url tools & {:as opts}]
  (cond-> {:type (name type) :url url :tools tools}
    (:timeout opts) (assoc :timeout (:timeout opts))
    (:headers opts) (assoc :headers (:headers opts))))

;; ============================================================================
;; Custom agent configuration
;; ============================================================================

(defn custom-agent-config
  "Create a custom agent configuration.

  `name`   - unique agent name
  `prompt` - agent prompt content
  Optional: :display-name :description :tools :mcp-servers :infer"
  [name prompt & {:as opts}]
  (cond-> {:name name :prompt prompt}
    (:display-name opts) (assoc :displayName (:display-name opts))
    (:description opts)  (assoc :description (:description opts))
    (contains? opts :tools) (assoc :tools (:tools opts))
    (:mcp-servers opts)  (assoc :mcpServers (:mcp-servers opts))
    (contains? opts :infer) (assoc :infer (:infer opts))))

;; ============================================================================
;; Infinite session configuration
;; ============================================================================

(defn infinite-session-config
  "Create an infinite session configuration.

  Optional: :enabled (default true),
            :background-compaction-threshold (0.0-1.0, default 0.80),
            :buffer-exhaustion-threshold (0.0-1.0, default 0.95)"
  [& {:as opts}]
  (let [{:keys [enabled background-compaction-threshold
                buffer-exhaustion-threshold]} opts]
    (cond-> {}
      (some? enabled) (assoc :enabled enabled)
      background-compaction-threshold
      (assoc :backgroundCompactionThreshold background-compaction-threshold)
      buffer-exhaustion-threshold
      (assoc :bufferExhaustionThreshold buffer-exhaustion-threshold))))

;; ============================================================================
;; Ping response
;; ============================================================================

(defn ping-response
  "Parse a raw ping response map."
  [m]
  {:message          (:message m)
   :timestamp        (:timestamp m)
   :protocol-version (:protocolVersion m)})

;; ============================================================================
;; Model information
;; ============================================================================

(defn model-info
  "Parse a raw model info map from JSON-RPC response."
  [m]
  {:id                          (:id m)
   :name                        (:name m)
   :capabilities                (:capabilities m)
   :policy                      (:policy m)
   :billing                     (:billing m)
   :supported-reasoning-efforts (:supportedReasoningEfforts m)
   :default-reasoning-effort    (:defaultReasoningEffort m)})

;; ============================================================================
;; Session metadata
;; ============================================================================

(defn session-metadata
  "Parse a raw session metadata map."
  [m]
  {:session-id    (:sessionId m)
   :start-time    (:startTime m)
   :modified-time (:modifiedTime m)
   :summary       (:summary m)
   :is-remote     (:isRemote m)})

;; ============================================================================
;; Session lifecycle events
;; ============================================================================

(defn session-lifecycle-event
  "Parse a raw session lifecycle event from JSON-RPC notification."
  [m]
  {:type       (:type m)
   :session-id (:sessionId m)
   :metadata   (:metadata m)})

;; ============================================================================
;; Response format & image generation
;; ============================================================================

(def response-formats #{:text :image :json-object})

(defn response-format->str
  "Convert a response format keyword to its JSON string representation."
  [fmt]
  (case fmt
    :text "text"
    :image "image"
    :json-object "json_object"
    (name fmt)))

(defn image-options
  "Create image options map for image generation.
   Options: :size (e.g. \"1024x1024\"), :quality (\"hd\" or \"standard\"), :style (\"natural\" or \"vivid\")"
  [& {:keys [size quality style]}]
  (cond-> {}
    size    (assoc :size size)
    quality (assoc :quality quality)
    style   (assoc :style style)))

(defn parse-assistant-image-data
  "Parse assistant image data from a response map."
  [data]
  {:format         (:format data)
   :base64         (:base64 data)
   :url            (:url data)
   :revised-prompt (:revisedPrompt data)
   :width          (:width data)
   :height         (:height data)})

(defn parse-content-block
  "Parse a content block from a mixed text+image response."
  [block]
  (case (:type block)
    "text"  {:type :text :text (:text block)}
    "image" {:type :image :image (parse-assistant-image-data (:image block))}
    block))

;; ============================================================================
;; Message options
;; ============================================================================

(defn message-options
  "Construct message options for sending a message.

  `prompt` - the message string
  Optional: :attachments (vector of attachment maps), :mode (:enqueue or :immediate),
            :response-format (keyword from response-formats), :image-options (image options map)"
  [prompt & {:as opts}]
  (cond-> {:prompt prompt}
    (:attachments opts)    (assoc :attachments (:attachments opts))
    (:mode opts)           (assoc :mode (name (:mode opts)))
    (:response-format opts) (assoc :response-format (response-format->str (:response-format opts)))
    (:image-options opts)  (assoc :image-options (:image-options opts))))

;; ============================================================================
;; Session hooks
;; ============================================================================

(defn session-hooks
  "Create a session hooks map.

  Optional keys:
    :on-pre-tool-use            (fn [input invocation] ...)
    :on-post-tool-use           (fn [input invocation] ...)
    :on-user-prompt-submitted   (fn [input invocation] ...)
    :on-session-start           (fn [input invocation] ...)
    :on-session-end             (fn [input invocation] ...)
    :on-error-occurred          (fn [input invocation] ...)"
  [& {:as opts}]
  (or opts {}))

;; ============================================================================
;; Client options
;; ============================================================================

(defn client-options
  "Create a client options map.

  Optional keys:
    :cli-path         - path to CLI executable (default: \"copilot\")
    :cli-args         - extra CLI arguments (vector of strings)
    :cwd              - working directory for CLI process
    :port             - TCP port (default 0 = random)
    :use-stdio        - use stdio transport (default true)
    :cli-url          - URL of existing server (mutually exclusive with :cli-path/:use-stdio)
    :log-level        - :none :error :warning :info :debug :all (default :info)
    :auto-start       - auto-start on first use (default true)
    :auto-restart     - auto-restart on crash (default true)
    :env              - environment variables map
    :github-token     - GitHub auth token
    :use-logged-in-user - use logged-in user auth (default true unless :github-token set)"
  [& {:as opts}]
  (or opts {}))

;; ============================================================================
;; Auth / Status response types
;; ============================================================================

(defn get-status-response
  "Parse a status.get response."
  [m]
  {:version          (:version m)
   :protocol-version (:protocolVersion m)})

(defn get-auth-status-response
  "Parse an auth.getStatus response."
  [m]
  {:is-authenticated (:isAuthenticated m)
   :auth-type        (:authType m)
   :host             (:host m)
   :login            (:login m)
   :status-message   (:statusMessage m)})
