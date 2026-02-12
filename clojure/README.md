# Copilot Supercharged SDK for Clojure

Clojure SDK for programmatic control of GitHub Copilot CLI via JSON-RPC 2.0.

> **Note:** This SDK is in technical preview and may change in breaking ways.

## Installation

### deps.edn

Add the SDK source path to your project or include it as a local dependency:

```clojure
{:deps {copilot-sdk-supercharged/clojure {:local/root "../copilot-sdk-supercharged/clojure"}}}
```

### Dependencies

The SDK requires:

- **Clojure** >= 1.11.0
- **cheshire** (JSON parsing)
- **core.async** (concurrency)
- **GitHub Copilot CLI** installed and available in PATH (or provide a custom `:cli-path`)

## Quick Start

```clojure
(require '[copilot.client :as client]
         '[copilot.session :as session])

;; Create and start client
(def my-client (client/create-client :log-level "info"))
(client/start! my-client)

;; Create a session
(def sess (client/create-session! my-client :model "gpt-5"))

;; Subscribe to events
(session/on-type! sess "assistant.message"
  (fn [event]
    (println "Assistant:" (get-in event [:data :content]))))

;; Send a message and wait for completion
(def result (session/send-and-wait! sess {:prompt "What is 2+2?"}))
(println "Response:" (get-in result [:data :content]))

;; Clean up
(session/destroy! sess)
(client/stop! my-client)
```

## Custom Tools

Define tools that the Copilot agent can call back into your process:

### Using the `deftool` macro

```clojure
(require '[copilot.define-tool :refer [deftool]])

(deftool lookup-fact
  "Returns a fun fact about a given topic."
  {:type       "object"
   :properties {:topic {:type        "string"
                        :description "Topic to look up"}}
   :required   ["topic"]}
  [args _invocation]
  (get my-facts (:topic args) "No fact found."))

;; Use in a session
(def sess (client/create-session! my-client :tools [lookup-fact]))
```

### Using the `define-tool` function

```clojure
(require '[copilot.define-tool :refer [define-tool]])

(def my-tool
  (define-tool "get_weather"
               "Get weather for a city"
               {:type       "object"
                :properties {:city {:type "string"}}
                :required   ["city"]}
               (fn [args _invocation]
                 (str "Weather in " (:city args) ": 22C, sunny"))))
```

Tool handlers can return:

- A **string** (wrapped as a success result)
- A **ToolResultObject map** with `:textResultForLlm` and `:resultType` (passed through)
- **Any other value** (JSON-serialised as a success result)
- **nil** (empty success)

Exceptions in handlers are caught and returned as failure results without exposing error details to the LLM.

## API Reference

### copilot.client

#### `create-client`

```clojure
(client/create-client & {:as opts})
```

Create a new CopilotClient (returns an atom).

**Options:**

| Key | Default | Description |
|-----|---------|-------------|
| `:cli-path` | `"copilot"` | Path to CLI executable |
| `:cli-args` | `[]` | Extra CLI arguments |
| `:cwd` | current dir | Working directory for CLI process |
| `:port` | `0` | TCP port (0 = random) |
| `:use-stdio` | `true` | Use stdio transport instead of TCP |
| `:cli-url` | nil | URL of existing server (mutually exclusive with `:cli-path`, `:use-stdio`) |
| `:log-level` | `"info"` | Log level |
| `:auto-start` | `true` | Auto-start on first use |
| `:auto-restart` | `true` | Auto-restart on crash |
| `:env` | nil | Environment variables map |
| `:github-token` | nil | GitHub token for authentication |
| `:use-logged-in-user` | `true` | Use logged-in user auth (false when `:github-token` set) |

#### `start!`

```clojure
(client/start! client-atom)
```

Start the CLI server and establish connection. Called automatically if `:auto-start` is true.

#### `stop!`

```clojure
(client/stop! client-atom) ;; => ["error1" "error2"] or []
```

Stop the server and close all sessions. Returns a vector of error messages.

#### `force-stop!`

```clojure
(client/force-stop! client-atom)
```

Force stop without graceful cleanup.

#### `create-session!`

```clojure
(client/create-session! client-atom & {:as config})
```

Create a new conversation session. Returns a session atom.

**Config keys:**

| Key | Description |
|-----|-------------|
| `:session-id` | Custom session ID |
| `:model` | Model to use (e.g., `"gpt-5"`, `"claude-sonnet-4.5"`) |
| `:reasoning-effort` | `:low`, `:medium`, `:high`, or `:xhigh` |
| `:tools` | Vector of tool maps |
| `:system-message` | System message config map |
| `:available-tools` | Vector of allowed tool names |
| `:excluded-tools` | Vector of disabled tool names |
| `:provider` | Custom provider config (BYOK) |
| `:on-permission-request` | Permission handler function |
| `:on-user-input-request` | User input handler function |
| `:hooks` | Session hooks map |
| `:working-directory` | Working directory for tool operations |
| `:streaming` | Enable streaming deltas |
| `:mcp-servers` | MCP server configurations |
| `:custom-agents` | Custom agent configurations |
| `:infinite-sessions` | Infinite session config |

#### `resume-session!`

```clojure
(client/resume-session! client-atom session-id & {:as config})
```

Resume an existing session by ID.

#### `ping!`

```clojure
(client/ping! client-atom) ;; => {:message "..." :timestamp 123 :protocol-version 2}
```

#### `list-models!`

```clojure
(client/list-models! client-atom) ;; => [{:id "gpt-5" :name "GPT-5" ...} ...]
```

Results are cached after the first call.

#### `list-sessions!`

```clojure
(client/list-sessions! client-atom) ;; => [{:session-id "..." :summary "..." ...} ...]
```

#### `delete-session!`

```clojure
(client/delete-session! client-atom "session-id")
```

#### `get-last-session-id!`

```clojure
(client/get-last-session-id! client-atom) ;; => "session-id" or nil
```

#### `on-lifecycle!`

```clojure
(def unsub (client/on-lifecycle! client-atom
             (fn [event]
               (println (:type event) (:session-id event)))))
(unsub) ;; unsubscribe
```

#### `on-lifecycle-type!`

```clojure
(def unsub (client/on-lifecycle-type! client-atom "session.created"
             (fn [event]
               (println "New session:" (:session-id event)))))
```

---

### copilot.session

#### `send!`

```clojure
(session/send! sess {:prompt "Hello"}) ;; => "message-id"
```

Send a message. Returns immediately with the message ID.

**Options:**

| Key | Description |
|-----|-------------|
| `:prompt` | Message text (required) |
| `:attachments` | Vector of attachment maps |
| `:mode` | `"enqueue"` or `"immediate"` |

#### `send-and-wait!`

```clojure
(session/send-and-wait! sess {:prompt "Hello"})
;; => {:type "assistant.message" :data {:content "..."}} or nil

;; With custom timeout (default 60s)
(session/send-and-wait! sess {:prompt "Hello"} 120000)
```

Send a message and block until the session becomes idle.

#### `on!`

```clojure
(def unsub (session/on! sess (fn [event] (println (:type event)))))
(unsub) ;; unsubscribe
```

Subscribe to all session events.

#### `on-type!`

```clojure
(def unsub (session/on-type! sess "assistant.message"
             (fn [event] (println (get-in event [:data :content])))))
```

Subscribe to a specific event type.

#### `abort!`

```clojure
(session/abort! sess)
```

Abort the currently processing message.

#### `get-messages!`

```clojure
(session/get-messages! sess) ;; => [{:type "..." :data {...}} ...]
```

Get all events/messages from the session history.

#### `destroy!`

```clojure
(session/destroy! sess)
```

Destroy the session and release resources.

#### `session-id`

```clojure
(session/session-id sess) ;; => "session-id-string"
```

#### `workspace-path`

```clojure
(session/workspace-path sess) ;; => "/path/to/workspace" or nil
```

---

### copilot.define-tool

#### `define-tool`

```clojure
(define-tool name description parameters handler-fn)
(define-tool name description handler-fn)  ;; no parameters
```

#### `deftool` (macro)

```clojure
(deftool var-name
  "Description for the LLM"
  {:type "object" :properties {...} :required [...]}  ;; optional JSON schema
  [args invocation]  ;; binding vector
  body...)
```

---

## Event Types

Sessions emit various events:

| Event Type | Description |
|------------|-------------|
| `user.message` | User message added |
| `assistant.message` | Final assistant response |
| `assistant.message_delta` | Streaming response chunk |
| `assistant.reasoning` | Reasoning content |
| `assistant.reasoning_delta` | Streaming reasoning chunk |
| `tool.execution_start` | Tool execution started |
| `tool.execution_complete` | Tool execution completed |
| `session.idle` | Session finished processing |
| `session.error` | Session error occurred |
| `session.compaction_start` | Background compaction started |
| `session.compaction_complete` | Compaction finished |

## Session Lifecycle Events (Client-level)

| Event Type | Description |
|------------|-------------|
| `session.created` | New session created |
| `session.deleted` | Session deleted |
| `session.updated` | Session updated |
| `session.foreground` | Session became foreground (TUI mode) |
| `session.background` | Session went to background (TUI mode) |

## Streaming

Enable streaming to receive response chunks incrementally:

```clojure
(def sess (client/create-session! my-client :model "gpt-5" :streaming true))

(session/on-type! sess "assistant.message_delta"
  (fn [event]
    (print (get-in event [:data :deltaContent]))
    (flush)))

(session/on-type! sess "assistant.message"
  (fn [event]
    (println "\n--- Final ---")
    (println (get-in event [:data :content]))))

(session/send-and-wait! sess {:prompt "Tell me a short story"})
```

## Custom Providers (BYOK)

```clojure
;; Ollama
(def sess (client/create-session! my-client
            :model "deepseek-coder-v2:16b"
            :provider {:baseUrl "http://localhost:11434/v1"}))

;; Azure OpenAI
(def sess (client/create-session! my-client
            :model "gpt-4"
            :provider {:type    "azure"
                       :baseUrl "https://my-resource.openai.azure.com"
                       :apiKey  (System/getenv "AZURE_OPENAI_KEY")
                       :azure   {:apiVersion "2024-10-21"}}))
```

## Permission Handling

```clojure
(def sess (client/create-session! my-client
            :on-permission-request
            (fn [request invocation]
              (println "Permission:" (:kind request))
              {:kind "approved"})))
```

## Session Hooks

```clojure
(def sess (client/create-session! my-client
            :hooks
            {:on-pre-tool-use
             (fn [input invocation]
               (println "Running:" (:toolName input))
               {:permissionDecision "allow"})

             :on-post-tool-use
             (fn [input invocation]
               (println "Done:" (:toolName input))
               nil)

             :on-session-start
             (fn [input invocation]
               (println "Session started from:" (:source input))
               {:additionalContext "Welcome!"})

             :on-session-end
             (fn [input invocation]
               (println "Session ended:" (:reason input)))}))
```

## Error Handling

```clojure
(try
  (def sess (client/create-session! my-client))
  (session/send-and-wait! sess {:prompt "Hello"})
  (catch clojure.lang.ExceptionInfo e
    (println "Error:" (.getMessage e))
    (println "Data:" (ex-data e))))
```

## Architecture

The SDK communicates with the Copilot CLI server via JSON-RPC 2.0:

- **Transport**: stdio (default) or TCP
- **Framing**: Content-Length header (`Content-Length: N\r\n\r\n{json}`)
- **Protocol version**: 2 (verified on connect via ping)
- **Server notifications**: `session.event`, `session.lifecycle`
- **Server requests**: `tool.call`, `permission.request`, `userInput.request`, `hooks.invoke`

## Requirements

- Clojure >= 1.11.0
- Java >= 11
- GitHub Copilot CLI installed and in PATH

## License

MIT
