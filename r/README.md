# Copilot Supercharged R SDK

R SDK for programmatic control of GitHub Copilot CLI via JSON-RPC 2.0 over stdio.

> **Note:** This SDK is in technical preview and may change in breaking ways.

## Installation

Install from source (requires R 4.1+):

```r
# Install dependencies
install.packages(c("jsonlite", "R6", "processx", "uuid"))

# Install from local source
install.packages("path/to/copilot-sdk-supercharged/r", repos = NULL, type = "source")
```

Or using `devtools`:

```r
devtools::install_local("path/to/copilot-sdk-supercharged/r")
```

## Quick Start

```r
library(copilot.sdk.supercharged)

# Create and start client
client <- CopilotClient$new()
client$start()

# Create a session
session <- client$create_session(model = "gpt-5")

# Subscribe to events
unsubscribe <- session$on(function(event) {
  if (event$type == "assistant.message") {
    cat(event$data$content, "\n")
  }
})

# Send a message and wait for the response
result <- session$send_and_wait(prompt = "What is 2+2?")
cat("Response:", result$data$content, "\n")

# Clean up
unsubscribe()
session$destroy()
client$stop()
```

## Features

- Full JSON-RPC 2.0 protocol support over stdio
- Content-Length header framing (Language Server Protocol style)
- Real-time streaming events via polling
- Custom tool registration with automatic result normalization
- Permission request handling
- User input request handling (ask_user tool)
- Session hooks for lifecycle interception
- Session history with `get_messages()`
- Protocol version verification
- R6 class-based API throughout

## API Reference

### CopilotClient

```r
client <- CopilotClient$new(
  cli_path = NULL,         # Path to CLI executable (default: searches PATH)
  cwd = getwd(),           # Working directory for CLI process
  log_level = "info",      # Log level ("none","error","warning","info","debug","all")
  auto_start = TRUE,       # Auto-start server on first use
  github_token = NULL,     # GitHub token for authentication
  use_logged_in_user = NULL, # Use stored OAuth / gh CLI auth (default: TRUE)
  env = NULL               # Additional environment variables (named list)
)

# Start the CLI server
client$start()

# Create a new session
session <- client$create_session(
  model = "gpt-5",
  tools = list(my_tool),
  streaming = TRUE
)

# Resume an existing session
session <- client$resume_session("session-id-here")

# Ping the server
ping <- client$ping()
cat(ping$message, ping$protocol_version)

# List available models
models <- client$list_models()
for (m in models) cat(m$id, m$name, "\n")

# List all sessions
sessions <- client$list_sessions()

# Delete a session
client$delete_session("session-id")

# Get connection state
state <- client$get_state()  # "disconnected", "connecting", "connected", "error"

# Subscribe to lifecycle events
unsub <- client$on(function(event) {
  cat(event$type, event$session_id, "\n")
})
unsub()  # Unsubscribe

# Stop the client
errors <- client$stop()

# Force stop (no graceful cleanup)
client$force_stop()
```

### CopilotSession

```r
# Send a message (non-blocking, returns message ID)
msg_id <- session$send(prompt = "Hello!")

# Send and wait for completion (blocking)
result <- session$send_and_wait(
  prompt = "Tell me a joke",
  timeout = 60  # seconds
)
cat(result$data$content)

# Subscribe to events
unsub <- session$on(function(event) {
  cat(sprintf("[%s] %s\n", event$type,
    if (!is.null(event$data$content)) event$data$content else ""))
})

# Get message history
events <- session$get_messages()

# Abort current processing
session$abort()

# Destroy session
session$destroy()
```

### Event Types

Events are `SessionEvent` R6 objects with these key types:

| Type | Description |
|------|-------------|
| `session.start` | Session started |
| `session.idle` | Session finished processing |
| `session.error` | Error occurred |
| `session.resume` | Session resumed |
| `session.shutdown` | Session shutting down |
| `user.message` | User message sent |
| `assistant.message` | Assistant response (final) |
| `assistant.message_delta` | Streaming message chunk |
| `assistant.reasoning` | Reasoning content (final) |
| `assistant.reasoning_delta` | Streaming reasoning chunk |
| `tool.execution_start` | Tool execution started |
| `tool.execution_complete` | Tool execution completed |
| `session.compaction_start` | Context compaction started |
| `session.compaction_complete` | Context compaction completed |

### Tools

Define custom tools using `define_tool()`:

```r
library(copilot.sdk.supercharged)

my_tool <- define_tool(
  name = "lookup_issue",
  description = "Fetch issue details from our tracker",
  parameters = list(
    type = "object",
    properties = list(
      id = list(type = "string", description = "Issue identifier")
    ),
    required = list("id")
  ),
  handler = function(invocation) {
    issue_id <- invocation$arguments$id
    # ... fetch the issue ...
    paste0("Issue ", issue_id, ": Fixed the login bug")
  }
)

session <- client$create_session(tools = list(my_tool))
```

**Handler return values:**

The handler function receives a `ToolInvocation` R6 object and can return:

- A character string (automatically wrapped as a success result)
- A `ToolResultObject` R6 object (for full control)
- A named list with `textResultForLlm` and `resultType` fields
- Any other value (JSON-serialized as a success result)

**Low-level Tool API:**

```r
my_tool <- Tool$new(
  name = "search",
  description = "Search the database",
  handler = function(invocation) {
    query <- invocation$arguments$query
    ToolResultObject$new(
      text_result_for_llm = paste0("Results for: ", query),
      result_type = "success",
      session_log = paste0("Searched: ", query)
    )
  },
  parameters = list(
    type = "object",
    properties = list(
      query = list(type = "string", description = "Search query")
    ),
    required = list("query")
  )
)
```

### Streaming

Enable streaming to receive response chunks as they are generated:

```r
session <- client$create_session(model = "gpt-5", streaming = TRUE)

session$on(function(event) {
  if (event$type == "assistant.message_delta") {
    cat(event$data$deltaContent %||% "", sep = "")
  } else if (event$type == "assistant.message") {
    cat("\n--- Final ---\n", event$data$content, "\n")
  }
})

session$send_and_wait(prompt = "Tell me a short story")
```

### Permission Requests

Handle permission requests from the agent:

```r
session <- client$create_session(
  on_permission_request = function(request, context) {
    cat(sprintf("Permission requested: %s\n", request$kind))
    # Return decision
    list(kind = "approved")
  }
)
```

### User Input Requests

Enable the agent to ask questions to the user:

```r
session <- client$create_session(
  on_user_input_request = function(request, context) {
    cat(sprintf("Agent asks: %s\n", request$question))
    UserInputResponse$new(answer = "Yes", was_freeform = TRUE)
  }
)
```

### Session Hooks

Intercept session lifecycle events:

```r
session <- client$create_session(
  hooks = list(
    on_pre_tool_use = function(input, context) {
      cat(sprintf("About to run: %s\n", input$toolName))
      list(permissionDecision = "allow")
    },
    on_post_tool_use = function(input, context) {
      cat(sprintf("Tool %s completed\n", input$toolName))
      NULL
    },
    on_session_start = function(input, context) {
      cat(sprintf("Session started from: %s\n", input$source))
      NULL
    },
    on_session_end = function(input, context) {
      cat(sprintf("Session ended: %s\n", input$reason))
      NULL
    }
  )
)
```

### Custom Providers

Use custom OpenAI-compatible API providers (BYOK):

```r
# Ollama (local)
session <- client$create_session(
  model = "deepseek-coder-v2:16b",
  provider = list(
    type = "openai",
    base_url = "http://localhost:11434/v1"
  )
)

# Azure OpenAI
session <- client$create_session(
  model = "gpt-4",
  provider = list(
    type = "azure",
    base_url = "https://my-resource.openai.azure.com",
    api_key = Sys.getenv("AZURE_OPENAI_KEY"),
    azure = list(api_version = "2024-10-21")
  )
)
```

### Infinite Sessions

Sessions use infinite sessions by default with automatic context compaction:

```r
# Default: infinite sessions enabled
session <- client$create_session(model = "gpt-5")
cat(session$workspace_path)

# Custom thresholds
session <- client$create_session(
  model = "gpt-5",
  infinite_sessions = list(
    enabled = TRUE,
    background_compaction_threshold = 0.80,
    buffer_exhaustion_threshold = 0.95
  )
)

# Disable infinite sessions
session <- client$create_session(
  model = "gpt-5",
  infinite_sessions = list(enabled = FALSE)
)
```

## Polling Model

R is single-threaded, so the SDK uses a **polling model** rather than true async/await.
The key methods that do blocking I/O are:

- `client$start()` -- connects and verifies protocol version
- `session$send_and_wait()` -- sends a message and polls until `session.idle`
- `client$request()` / `session$send()` -- sends a JSON-RPC request and polls for the response

For integrations that need non-blocking event processing (e.g. Shiny apps),
use `client$poll(timeout_ms)` in a reactive timer:

```r
# In a Shiny app
observe({
  invalidateLater(100)  # Poll every 100ms
  client$poll(timeout_ms = 50)
})
```

## Requirements

- R 4.1+
- GitHub Copilot CLI installed and accessible in PATH
- R packages: jsonlite, R6, processx, uuid
