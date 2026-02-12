# GitHub Copilot Supercharged SDK for Kotlin

The Kotlin SDK for the GitHub Copilot CLI provides a coroutine-based interface for communicating with the Copilot CLI server via JSON-RPC 2.0 over stdio or TCP.

## Requirements

- Kotlin 1.9+
- JDK 17+
- The Copilot CLI installed and available on PATH (or set `COPILOT_CLI_PATH` environment variable)
- Active GitHub Copilot authentication

## Installation

### Gradle (Kotlin DSL)

```kotlin
dependencies {
    implementation("com.github.copilot:copilot-sdk-supercharged-kotlin:0.1.0")
}
```

### Building from source

```bash
cd kotlin
./gradlew build
```

## Quick Start

```kotlin
import com.github.copilot.*
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    // Create a client (auto-spawns the CLI server)
    val client = CopilotClient()

    // Create a session
    val session = client.createSession()

    // Subscribe to events
    session.on { event ->
        println("[${event.type}] ${event.data}")
    }

    // Send a message and wait for the response
    val response = session.sendAndWait(MessageOptions(prompt = "What is 2+2?"))
    println("Response: ${response?.data}")

    // Clean up
    session.destroy()
    client.stop()
}
```

## Architecture

The SDK communicates with the Copilot CLI server using the JSON-RPC 2.0 protocol over stdio (default) or TCP. The CLI server is spawned as a subprocess with the flags `--headless --no-auto-update --log-level info --stdio`.

```
Your Application
    |
    v
CopilotClient  (manages CLI process lifecycle)
    |
    v
JsonRpcClient  (JSON-RPC 2.0 with Content-Length header framing)
    |
    v
CLI Process    (stdin/stdout pipes or TCP socket)
```

### Key Components

- **`CopilotClient`** - Main entry point. Spawns the CLI process, connects via stdio/TCP, manages sessions, and handles server requests (tool calls, permissions, user input, hooks).
- **`CopilotSession`** - Represents a conversation. Send messages, subscribe to events, register tools.
- **`JsonRpcClient`** - Low-level JSON-RPC 2.0 transport layer using Content-Length header framing, coroutines for async I/O, and `CompletableDeferred` for pending requests.

## Client Options

```kotlin
val client = CopilotClient(CopilotClientOptions(
    // Path to the CLI executable (default: "copilot" or COPILOT_CLI_PATH env)
    cliPath = "/usr/local/bin/copilot",

    // Extra arguments for the CLI
    cliArgs = listOf("--extra-flag"),

    // Working directory for the CLI process
    cwd = "/path/to/project",

    // Use stdio transport (default: true)
    useStdio = true,

    // Or connect to an existing server via TCP
    // cliUrl = "localhost:3000",

    // Log level: "none", "error", "warning", "info", "debug", "all"
    logLevel = "info",

    // Auto-start on first use (default: true)
    autoStart = true,

    // Auto-restart on crash (default: true)
    autoRestart = true,

    // GitHub token for authentication
    // githubToken = "ghp_...",
))
```

## Sessions

### Creating a Session

```kotlin
val session = client.createSession(SessionConfig(
    model = "gpt-4",
    workingDirectory = "/path/to/project",
    streaming = true,
))
```

### Resuming a Session

```kotlin
val session = client.resumeSession("session-id-123", ResumeSessionConfig(
    model = "gpt-4",
))
```

### Sending Messages

```kotlin
// Fire-and-forget (events come via on() handler)
val messageId = session.send(MessageOptions(prompt = "Hello!"))

// Send and wait for completion
val response = session.sendAndWait(
    MessageOptions(prompt = "Explain this code"),
    timeoutMs = 120_000  // 2 minute timeout
)
```

### Event Handling

```kotlin
// Listen to all events
val unsubscribe = session.on { event ->
    when (event.type) {
        "assistant.message" -> println("Assistant: ${event.data}")
        "assistant.message_delta" -> print(event.data?.get("deltaContent") ?: "")
        "tool.executing" -> println("Executing tool...")
        "session.idle" -> println("Session is idle")
        "session.error" -> println("Error: ${event.data}")
    }
}

// Listen to a specific event type
val unsub2 = session.on("assistant.message") { event ->
    println(event.data)
}

// Unsubscribe when done
unsubscribe()
unsub2()
```

## Custom Tools

### Using the DSL Builder

```kotlin
val weatherTool = defineTool("get_weather") {
    description = "Get weather for a location"
    parameters = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "location" to mapOf("type" to "string", "description" to "City name")
        ),
        "required" to listOf("location")
    )
    handler = { args, invocation ->
        // args is a JsonElement from the server
        val location = (args as? kotlinx.serialization.json.JsonObject)
            ?.get("location")
            ?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
            ?: "unknown"
        "72F and sunny in $location"
    }
}

val session = client.createSession(SessionConfig(
    tools = listOf(weatherTool)
))
```

### Using createTool

```kotlin
val tool = createTool(
    name = "add_numbers",
    description = "Add two numbers",
    parameters = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "a" to mapOf("type" to "number"),
            "b" to mapOf("type" to "number")
        ),
        "required" to listOf("a", "b")
    )
) { args, _ ->
    val obj = args as? kotlinx.serialization.json.JsonObject
    val a = obj?.get("a")?.jsonPrimitive?.doubleOrNull ?: 0.0
    val b = obj?.get("b")?.jsonPrimitive?.doubleOrNull ?: 0.0
    a + b
}
```

### Structured Tool Results

Return a `ToolResultObject` for full control over the result:

```kotlin
handler = { args, _ ->
    ToolResultObject(
        textResultForLlm = "The operation completed successfully.",
        resultType = "success",
        toolTelemetry = mapOf("duration_ms" to kotlinx.serialization.json.JsonPrimitive(42))
    )
}
```

## Permission Handling

```kotlin
val session = client.createSession(SessionConfig(
    onPermissionRequest = { request, sessionId ->
        println("Permission requested: ${request.kind}")
        // Approve all shell commands for this example
        if (request.kind == "shell") {
            PermissionRequestResult(kind = "approved")
        } else {
            PermissionRequestResult(kind = "denied-interactively-by-user")
        }
    }
))
```

## User Input Handling

```kotlin
val session = client.createSession(SessionConfig(
    onUserInputRequest = { request, sessionId ->
        println("Agent asks: ${request.question}")
        if (request.choices != null) {
            println("Choices: ${request.choices}")
        }
        // Return a response
        UserInputResponse(
            answer = "yes",
            wasFreeform = false
        )
    }
))
```

## Session Hooks

```kotlin
val session = client.createSession(SessionConfig(
    hooks = SessionHooks(
        onPreToolUse = { input, sessionId ->
            println("About to use tool: ${input["toolName"]}")
            // Return null to proceed normally, or return a map with decisions
            mapOf("permissionDecision" to "allow")
        },
        onPostToolUse = { input, sessionId ->
            println("Tool finished: ${input["toolName"]}")
            null
        },
        onSessionStart = { input, sessionId ->
            println("Session started from: ${input["source"]}")
            null
        },
        onSessionEnd = { input, sessionId ->
            println("Session ended: ${input["reason"]}")
            null
        },
        onErrorOccurred = { input, sessionId ->
            println("Error occurred: ${input["error"]}")
            null
        }
    )
))
```

## Client Lifecycle Operations

```kotlin
// Ping the server
val ping = client.ping("health check")
println("Protocol version: ${ping.protocolVersion}")

// Get CLI status
val status = client.getStatus()
println("CLI version: ${status.version}")

// Get auth status
val auth = client.getAuthStatus()
println("Authenticated: ${auth.isAuthenticated}")

// List available models
val models = client.listModels()
models.forEach { println("${it.id}: ${it.name}") }

// List sessions
val sessions = client.listSessions()
sessions.forEach { println("${it.sessionId}: ${it.summary}") }

// Delete a session
client.deleteSession("session-id-123")

// Session lifecycle events
val unsub = client.onLifecycle { event ->
    println("Lifecycle: ${event.type} for session ${event.sessionId}")
}
val unsub2 = client.onLifecycle("session.created") { event ->
    println("New session: ${event.sessionId}")
}
```

## Custom Provider (BYOK)

```kotlin
val session = client.createSession(SessionConfig(
    provider = ProviderConfig(
        type = "openai",
        baseUrl = "https://api.openai.com/v1",
        apiKey = "sk-..."
    ),
    model = "gpt-4"
))
```

## MCP Server Integration

```kotlin
val session = client.createSession(SessionConfig(
    mcpServers = mapOf(
        "my-server" to MCPServerConfig(
            tools = listOf("*"),
            command = "node",
            args = listOf("./mcp-server.js"),
        )
    )
))
```

## Protocol Details

- **Transport**: stdio (default) or TCP
- **Framing**: Content-Length header (LSP base protocol)
- **Protocol**: JSON-RPC 2.0
- **Protocol Version**: 2 (verified via ping on connection)

### Message Flow

1. Client spawns CLI with `--headless --no-auto-update --log-level info --stdio`
2. Client verifies protocol version via `ping` response
3. Client creates sessions via `session.create` request
4. Client sends messages via `session.send` request
5. Server sends `session.event` notifications with events
6. Server sends `tool.call` requests for custom tool execution
7. Server sends `permission.request` requests for permission decisions
8. Server sends `userInput.request` requests for user input
9. Server sends `hooks.invoke` requests for hook execution
10. Server sends `session.lifecycle` notifications for session state changes

## License

MIT License. See [LICENSE](../LICENSE) for details.
