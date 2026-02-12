# Copilot Supercharged SDK for Rust

A Rust client library for programmatic control of GitHub Copilot CLI via JSON-RPC 2.0.

This SDK communicates with the Copilot CLI server using JSON-RPC 2.0 over stdio or TCP, with Content-Length header framing (LSP protocol style). It follows the same architecture as the official Node.js, Python, Go, and .NET SDKs.

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
copilot-sdk-supercharged = { path = "../rust" }
tokio = { version = "1", features = ["full"] }
serde_json = "1"
```

Or if published to crates.io:

```toml
[dependencies]
copilot-sdk-supercharged = "0.1"
tokio = { version = "1", features = ["full"] }
```

## Quick Start

```rust
use copilot_sdk::*;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<(), CopilotError> {
    // Create and start a client
    let client = CopilotClient::new(CopilotClientOptions {
        cli_path: Some("/path/to/copilot-cli".to_string()),
        ..Default::default()
    });
    client.start().await?;

    // Create a session
    let session = client.create_session(SessionConfig::default()).await?;

    // Subscribe to events
    let _sub = session.on(|event| {
        if let Some(content) = event.assistant_message_content() {
            println!("Assistant: {}", content);
        }
    }).await;

    // Send a message and wait for the response
    let response = session.send_and_wait(
        MessageOptions {
            prompt: "What is 2 + 2?".to_string(),
            attachments: None,
            mode: None,
        },
        None, // default 60s timeout
    ).await?;

    if let Some(event) = response {
        if let Some(content) = event.assistant_message_content() {
            println!("Answer: {}", content);
        }
    }

    // Clean up
    session.destroy().await?;
    client.stop().await?;
    Ok(())
}
```

## Custom Tools

You can register custom tools that the Copilot agent can invoke during a session:

```rust
use copilot_sdk::*;
use std::sync::Arc;

// Define a tool
let tool_def = ToolDefinition {
    name: "get_weather".to_string(),
    description: Some("Get weather for a location".to_string()),
    parameters: Some(serde_json::json!({
        "type": "object",
        "properties": {
            "location": {
                "type": "string",
                "description": "City name"
            }
        },
        "required": ["location"]
    })),
};

// Create a handler
let handler: ToolHandler = Arc::new(|args, _invocation| {
    Box::pin(async move {
        let location = args.get("location")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown");
        Ok(serde_json::json!({
            "location": location,
            "temperature": 72,
            "condition": "sunny"
        }))
    })
});

// Create session with the tool
let config = SessionConfig {
    tools: Some(vec![tool_def.clone()]),
    ..Default::default()
};
let session = client.create_session(config).await?;

// Register the handler
session.register_tool("get_weather", handler).await;
```

## Permission Handling

Register a handler to approve or deny permission requests from the agent:

```rust
use copilot_sdk::*;
use std::sync::Arc;

let perm_handler: PermissionHandlerFn = Arc::new(|request, session_id| {
    Box::pin(async move {
        println!("Permission request from session {}: {:?}", session_id, request.kind);
        // Auto-approve read operations
        if request.kind == PermissionKind::Read {
            Ok(PermissionRequestResult {
                kind: PermissionResultKind::Approved,
                rules: None,
            })
        } else {
            Ok(PermissionRequestResult {
                kind: PermissionResultKind::DeniedInteractivelyByUser,
                rules: None,
            })
        }
    })
});

session.register_permission_handler(perm_handler).await;
```

## User Input Handling

Enable the ask_user tool by registering a user input handler:

```rust
use copilot_sdk::*;
use std::sync::Arc;

let input_handler: UserInputHandlerFn = Arc::new(|request, _session_id| {
    Box::pin(async move {
        println!("Agent asks: {}", request.question);
        Ok(UserInputResponse {
            answer: "Yes, proceed.".to_string(),
            was_freeform: true,
        })
    })
});

session.register_user_input_handler(input_handler).await;
```

## Event Subscription

Subscribe to all events or specific event types:

```rust
// All events
let sub = session.on(|event| {
    println!("[{}] {}", event.event_type, event.id);
}).await;

// Specific event type
let sub = session.on_event("assistant.message", |event| {
    if let Some(content) = event.assistant_message_content() {
        println!("Message: {}", content);
    }
}).await;

// Unsubscribe explicitly (also happens on drop)
sub.unsubscribe();
```

### Event Types

| Event Type | Description |
|---|---|
| `session.start` | Session started |
| `session.resume` | Session resumed |
| `session.idle` | Session finished processing |
| `session.error` | Error occurred |
| `session.info` | Informational message |
| `session.model_change` | Model changed |
| `session.truncation` | Context truncated |
| `session.compaction_start` | Context compaction started |
| `session.compaction_complete` | Context compaction finished |
| `user.message` | User message sent |
| `assistant.message` | Final assistant response |
| `assistant.message_delta` | Streaming response chunk |
| `assistant.reasoning` | Reasoning content |
| `assistant.reasoning_delta` | Streaming reasoning chunk |
| `assistant.turn_start` | Assistant turn started |
| `assistant.turn_end` | Assistant turn ended |
| `assistant.usage` | Token usage information |
| `tool.execution_start` | Tool execution started |
| `tool.execution_complete` | Tool execution finished |
| `tool.execution_progress` | Tool execution progress |
| `abort` | Session aborted |

## API Reference

### CopilotClient

| Method | Description |
|---|---|
| `CopilotClient::new(options)` | Create a new client |
| `client.start()` | Start the CLI server and connect |
| `client.stop()` | Stop the server and clean up sessions |
| `client.force_stop()` | Force stop without graceful cleanup |
| `client.create_session(config)` | Create a new session |
| `client.resume_session(config)` | Resume an existing session |
| `client.delete_session(id)` | Delete a session permanently |
| `client.list_sessions()` | List all sessions |
| `client.get_last_session_id()` | Get the most recent session ID |
| `client.ping(message)` | Ping the server |
| `client.get_status()` | Get CLI version and protocol info |
| `client.get_auth_status()` | Get authentication status |
| `client.list_models()` | List available models (cached) |
| `client.get_state()` | Get current connection state |
| `client.on_lifecycle(handler)` | Subscribe to lifecycle events |

### CopilotSession

| Method | Description |
|---|---|
| `session.send(options)` | Send a message (async, non-blocking) |
| `session.send_and_wait(options, timeout)` | Send and wait for idle |
| `session.on(handler)` | Subscribe to all events |
| `session.on_event(type, handler)` | Subscribe to specific event type |
| `session.register_tool(name, handler)` | Register a tool handler |
| `session.register_permission_handler(h)` | Register permission handler |
| `session.register_user_input_handler(h)` | Register user input handler |
| `session.register_hooks_handler(h)` | Register hooks handler |
| `session.get_messages()` | Get session history |
| `session.destroy()` | Destroy the session |
| `session.abort()` | Abort current processing |
| `session.session_id()` | Get session ID |
| `session.workspace_path()` | Get workspace path |

### CopilotClientOptions

| Field | Type | Default | Description |
|---|---|---|---|
| `cli_path` | `Option<String>` | `None` | Path to CLI executable |
| `cli_args` | `Vec<String>` | `[]` | Extra CLI arguments |
| `cwd` | `Option<String>` | `None` | Working directory |
| `port` | `u16` | `0` | TCP port (0 = random) |
| `use_stdio` | `bool` | `true` | Use stdio transport |
| `cli_url` | `Option<String>` | `None` | External server URL |
| `log_level` | `String` | `"info"` | CLI log level |
| `auto_start` | `bool` | `true` | Auto-start on first use |
| `auto_restart` | `bool` | `true` | Auto-restart on crash |
| `env` | `Option<HashMap>` | `None` | Environment variables |
| `github_token` | `Option<String>` | `None` | GitHub auth token |
| `use_logged_in_user` | `Option<bool>` | `None` | Use stored OAuth |

## Connection Modes

### stdio (default)

The client spawns the CLI process and communicates via stdin/stdout pipes.
This is the recommended mode for most use cases.

```rust
let client = CopilotClient::new(CopilotClientOptions {
    cli_path: Some("/path/to/copilot-cli".to_string()),
    use_stdio: true, // default
    ..Default::default()
});
```

### TCP

The client spawns the CLI process with a TCP listener and connects via socket.

```rust
let client = CopilotClient::new(CopilotClientOptions {
    cli_path: Some("/path/to/copilot-cli".to_string()),
    use_stdio: false,
    port: 0, // random port
    ..Default::default()
});
```

### External Server

Connect to an already-running CLI server.

```rust
let client = CopilotClient::new(CopilotClientOptions {
    cli_url: Some("localhost:3000".to_string()),
    ..Default::default()
});
```

## Protocol Version

The SDK verifies protocol compatibility with the server on startup. The current protocol version is **2**. If there is a mismatch, the `start()` call returns a `CopilotError::ProtocolMismatch` error.

## Error Handling

All fallible operations return `Result<T, CopilotError>`. Error variants include:

- `CopilotError::JsonRpc` - Server returned a JSON-RPC error
- `CopilotError::Timeout` - Request timed out
- `CopilotError::ConnectionClosed` - Connection dropped
- `CopilotError::ProtocolMismatch` - SDK/server version incompatible
- `CopilotError::SessionError` - Session-level error
- `CopilotError::NotConnected` - Client not connected
- `CopilotError::ProcessSpawn` - Failed to start CLI process

## License

MIT - See [LICENSE](../LICENSE) for details.
