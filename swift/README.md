# Copilot Supercharged SDK for Swift

A Swift SDK for interacting with the GitHub Copilot CLI via JSON-RPC 2.0 over stdio.

## Requirements

- Swift 5.9+
- macOS 13+ / iOS 16+ / tvOS 16+ / watchOS 9+
- GitHub Copilot CLI installed and available in PATH (or provide a custom path)

## Installation

### Swift Package Manager

Add the following to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged", from: "1.0.0")
```

Then add `"CopilotSDK"` as a dependency of your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["CopilotSDK"]
)
```

## Quick Start

```swift
import CopilotSDK

// Create a client (auto-starts the CLI server)
let client = CopilotClient()

// Create a session
let session = try await client.createSession()

// Subscribe to events
await session.on { event in
    if event.type == "assistant.message" {
        print(event.data["content"] as? String ?? "")
    }
}

// Send a message and wait for the response
let response = try await session.sendAndWait(
    MessageOptions(prompt: "Explain what a Swift actor is")
)
print(response?.data["content"] as? String ?? "No response")

// Clean up
try await session.destroy()
await client.stop()
```

## Architecture

The SDK follows the same patterns as the official Node.js, Python, Go, and .NET SDKs:

```
CopilotClient
  |-- spawns CLI process with --headless --stdio
  |-- JsonRpcClient (Content-Length framed JSON-RPC 2.0 over stdin/stdout)
  |-- manages CopilotSession instances
```

### Key Components

| File | Description |
|------|-------------|
| `CopilotClient.swift` | Main client: spawns CLI, manages connections and sessions |
| `CopilotSession.swift` | Session: send/receive messages, event subscriptions, tool handling |
| `JsonRpcClient.swift` | JSON-RPC 2.0 client with Content-Length header framing |
| `Types.swift` | All type definitions (Codable structs, enums, typealiases) |
| `DefineTool.swift` | Helper for defining tools with typed parameters |
| `SdkProtocolVersion.swift` | Protocol version constant (must match CLI server) |

## Core Concepts

### Client

The `CopilotClient` is the entry point. It spawns the Copilot CLI process and manages the JSON-RPC connection.

```swift
// Default options (stdio transport, auto-start)
let client = CopilotClient()

// Custom options
let client = CopilotClient(options: CopilotClientOptions(
    cliPath: "/usr/local/bin/copilot",
    logLevel: "debug"
))

// Connect to an existing server
let client = CopilotClient(options: CopilotClientOptions(
    cliUrl: "localhost:3000"
))

// Explicit start (if autoStart is false)
try await client.start()
```

### Sessions

Sessions maintain conversation state. Create, resume, or list them:

```swift
// Create a new session
let session = try await client.createSession(SessionConfig(
    model: "gpt-4",
    streaming: true
))

// Resume an existing session
let session = try await client.resumeSession("session-id-here")

// List all sessions
let sessions = try await client.listSessions()

// Delete a session
try await client.deleteSession("session-id-here")
```

### Sending Messages

```swift
// Fire and forget (events delivered via handlers)
try await session.send(MessageOptions(prompt: "Hello"))

// Send and wait for completion (blocks until session.idle)
let response = try await session.sendAndWait(
    MessageOptions(prompt: "What is 2+2?"),
    timeout: 30  // seconds
)

// With attachments
try await session.send(MessageOptions(
    prompt: "Explain this file",
    attachments: [.file(path: "/path/to/file.swift")]
))
```

### Event Handling

```swift
// Subscribe to all events
let handlerId = await session.on { event in
    switch event.type {
    case "assistant.message":
        print("Assistant: \(event.data["content"] ?? "")")
    case "assistant.message_delta":
        // Streaming delta
        print(event.data["deltaContent"] ?? "", terminator: "")
    case "tool.execution_start":
        print("Tool: \(event.data["toolName"] ?? "")")
    case "session.error":
        print("Error: \(event.data["message"] ?? "")")
    default:
        break
    }
}

// Subscribe to a specific event type
await session.on("assistant.message") { event in
    print(event.data["content"] as? String ?? "")
}

// Unsubscribe
await session.removeEventHandler(handlerId)
```

### Tools

Define custom tools that the agent can invoke:

```swift
// Using typed parameters (recommended)
struct SearchParams: Codable {
    let query: String
    let maxResults: Int?
}

let searchTool = defineTool(
    name: "search",
    description: "Search for information",
    parametersType: SearchParams.self
) { (params: SearchParams, invocation) -> Any? in
    // Your search logic here
    return "Results for: \(params.query)"
}

// Using explicit JSON schema
let simpleTool = defineTool(
    name: "get_time",
    description: "Get the current time"
) { invocation -> Any? in
    return ISO8601DateFormatter().string(from: Date())
}

// Pass tools to session
let session = try await client.createSession(SessionConfig(
    tools: [searchTool, simpleTool]
))
```

### Permissions

Handle permission requests when the agent needs to perform sensitive operations:

```swift
let session = try await client.createSession(SessionConfig(
    onPermissionRequest: { request, sessionId in
        print("Permission requested: \(request.kind)")
        // Approve all read operations, deny everything else
        if request.kind == "read" {
            return .approved
        }
        return .deniedByUser
    }
))
```

### User Input (ask_user)

Handle questions from the agent to the user:

```swift
let session = try await client.createSession(SessionConfig(
    onUserInputRequest: { request, sessionId in
        print("Agent asks: \(request.question)")
        // In a real app, prompt the user for input
        return UserInputResponse(answer: "Yes", wasFreeform: true)
    }
))
```

### Hooks

Intercept session lifecycle events:

```swift
let session = try await client.createSession(SessionConfig(
    hooks: SessionHooks(
        onPreToolUse: { input, sessionId in
            print("About to use tool: \(input.toolName)")
            return PreToolUseHookOutput(permissionDecision: "allow")
        },
        onPostToolUse: { input, sessionId in
            print("Tool \(input.toolName) completed")
            return nil
        },
        onSessionStart: { input, sessionId in
            print("Session started from: \(input.source)")
            return nil
        }
    )
))
```

### Custom Providers (BYOK)

Use your own API key with OpenAI, Azure, or Anthropic:

```swift
let session = try await client.createSession(SessionConfig(
    provider: ProviderConfig(
        baseUrl: "https://api.openai.com/v1",
        type: "openai",
        apiKey: "sk-..."
    )
))
```

### MCP Servers

Configure Model Context Protocol servers:

```swift
let session = try await client.createSession(SessionConfig(
    mcpServers: [
        "my-server": .local(
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/path"],
            tools: ["*"]
        ),
        "remote-server": .http(
            url: "https://mcp.example.com",
            headers: ["Authorization": "Bearer token"]
        )
    ]
))
```

### Models

List available models:

```swift
let models = try await client.listModels()
for model in models {
    print("\(model.id): \(model.name)")
    if model.capabilities.supports.reasoningEffort {
        print("  Supports reasoning effort: \(model.supportedReasoningEfforts ?? [])")
    }
}
```

### Session Lifecycle Events

Monitor session lifecycle changes (useful in TUI+server mode):

```swift
let handlerId = await client.onLifecycleEvent { event in
    switch event.type {
    case .created:
        print("Session created: \(event.sessionId)")
    case .deleted:
        print("Session deleted: \(event.sessionId)")
    case .foreground:
        print("Session foregrounded: \(event.sessionId)")
    default:
        break
    }
}
```

## Concurrency Model

The SDK uses Swift concurrency throughout:

- `CopilotClient` and `CopilotSession` are **actors**, providing thread-safe access to mutable state.
- All async operations use `async/await`.
- Event handlers and tool handlers are `@Sendable` closures.
- The `JsonRpcClient` is an actor that manages the stdio read/write loop.

## Protocol

The SDK communicates with the Copilot CLI using JSON-RPC 2.0 with Content-Length header framing (the same protocol used by LSP):

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":"1","method":"ping","params":{}}
```

### Client-to-Server Methods

| Method | Description |
|--------|-------------|
| `ping` | Health check, returns protocol version |
| `status.get` | Get CLI version and protocol info |
| `auth.getStatus` | Get authentication status |
| `models.list` | List available models |
| `session.create` | Create a new session |
| `session.resume` | Resume an existing session |
| `session.send` | Send a message to a session |
| `session.destroy` | Destroy a session |
| `session.abort` | Abort current processing |
| `session.getMessages` | Get session history |
| `session.list` | List all sessions |
| `session.delete` | Delete a session from disk |
| `session.getLastId` | Get most recent session ID |
| `session.getForeground` | Get foreground session (TUI mode) |
| `session.setForeground` | Set foreground session (TUI mode) |

### Server-to-Client Notifications

| Method | Description |
|--------|-------------|
| `session.event` | Session event (messages, tool use, etc.) |
| `session.lifecycle` | Session lifecycle changes |

### Server-to-Client Requests

| Method | Description |
|--------|-------------|
| `tool.call` | Invoke a registered tool |
| `permission.request` | Request permission for an operation |
| `userInput.request` | Request user input (ask_user) |
| `hooks.invoke` | Invoke a session hook |

## Running the Example

```bash
cd swift
swift run BasicExample
```

## License

See the [LICENSE](../LICENSE) file in the repository root.
