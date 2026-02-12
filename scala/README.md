# Copilot SDK for Scala

Scala 3 SDK for the [GitHub Copilot CLI](https://github.com/github/copilot). Communicates with the Copilot CLI server via JSON-RPC 2.0 over stdio or TCP.

## Requirements

- **Scala 3.4+** with **sbt 1.10+**
- **GitHub Copilot CLI** installed and available on your PATH (or specify via `cliPath`)
- **JDK 17+**

## Installation

Add the SDK to your `build.sbt`:

```scala
// Until published to Maven Central, use a local dependency or publishLocal
lazy val copilotSdk = ProjectRef(file("path/to/copilot-sdk/scala"), "root")

lazy val myProject = project
  .dependsOn(copilotSdk)
```

Or publish locally and add as a library dependency:

```bash
cd copilot-sdk/scala
sbt publishLocal
```

```scala
libraryDependencies += "com.github.copilot" %% "copilot-sdk" % "0.1.0"
```

## Quick Start

```scala
import com.github.copilot.*
import io.circe.*
import io.circe.syntax.*
import scala.concurrent.{Await, ExecutionContext, Future}
import scala.concurrent.duration.*

given ExecutionContext = ExecutionContext.global

// Create and start the client
val client = CopilotClient()
Await.result(client.start(), 30.seconds)

// Create a session
val session = Await.result(client.createSession(), 30.seconds)

// Subscribe to events
session.on { event =>
  if event.`type` == SessionEventType.AssistantMessage then
    val content = event.data.hcursor.get[String]("content").getOrElse("")
    println(s"Assistant: $content")
}

// Send a message and wait for the response
val response = Await.result(
  session.sendAndWait(MessageOptions(prompt = "What is Scala?")),
  60.seconds
)

// Clean up
Await.result(session.destroy(), 10.seconds)
client.stop()
```

## Architecture

The SDK follows the same architecture as the Node.js, Python, Go, and .NET SDKs:

```
CopilotClient
  |-- spawns CLI process (--headless --no-auto-update --stdio)
  |-- JsonRpcClient (Content-Length header framing)
  |     |-- sendRequest() / sendNotification()
  |     |-- onRequest() / onNotification()
  |-- CopilotSession (one per conversation)
        |-- send() / sendAndWait()
        |-- on() event subscriptions
        |-- tool handlers
        |-- permission/userInput/hooks handlers
```

### JSON-RPC 2.0 Protocol

Messages use **Content-Length header framing** (same as LSP):

```
Content-Length: 73\r\n
\r\n
{"jsonrpc":"2.0","id":"abc-123","method":"ping","params":{"message":"hi"}}
```

### Transport Modes

- **stdio** (default): Communicates via stdin/stdout of the spawned CLI process
- **TCP**: Connects to an existing CLI server over a TCP socket

## API Reference

### CopilotClient

The main entry point. Manages the CLI process and JSON-RPC connection.

```scala
val client = CopilotClient(CopilotClientOptions(
  cliPath = Some("/usr/local/bin/copilot"),
  logLevel = "debug",
  useStdio = true
))
```

| Method | Description |
|--------|-------------|
| `start(): Future[Unit]` | Start the CLI server and connect |
| `stop(): List[Throwable]` | Gracefully stop and return cleanup errors |
| `forceStop(): Unit` | Forcefully stop without cleanup |
| `createSession(config): Future[CopilotSession]` | Create a new session |
| `resumeSession(id, config): Future[CopilotSession]` | Resume an existing session |
| `ping(message): Future[PingResponse]` | Ping the server |
| `getStatus(): Future[GetStatusResponse]` | Get CLI status |
| `getAuthStatus(): Future[GetAuthStatusResponse]` | Get auth status |
| `listModels(): Future[List[ModelInfo]]` | List available models (cached) |
| `deleteSession(id): Future[Unit]` | Delete a session |
| `listSessions(): Future[List[SessionMetadata]]` | List all sessions |

### CopilotSession

Represents a single conversation. Created via `client.createSession()`.

| Method | Description |
|--------|-------------|
| `send(options): Future[String]` | Send a message, returns message ID |
| `sendAndWait(options, timeout): Future[Option[SessionEvent]]` | Send and wait for idle |
| `on(handler): () => Unit` | Subscribe to all events |
| `on(eventType, handler): () => Unit` | Subscribe to specific event type |
| `getMessages(): Future[List[SessionEvent]]` | Get message history |
| `destroy(): Future[Unit]` | Destroy the session |
| `abort(): Future[Unit]` | Abort current processing |

### DefineTool

Helper for creating tools with a clean builder API:

```scala
val myTool = DefineTool(
  name = "my_tool",
  description = "Does something useful",
  parameters = JsonObject(
    "type" -> "object".asJson,
    "properties" -> Json.obj(
      "input" -> Json.obj("type" -> "string".asJson)
    ),
    "required" -> Json.arr("input".asJson)
  )
) { (args, invocation) =>
  val input = args.hcursor.get[String]("input").getOrElse("")
  Future.successful(ToolResultObject(
    textResultForLlm = s"Processed: $input",
    resultType = ToolResultType.Success
  ))
}
```

Convenience variants:

- `DefineTool.sync(...)` -- synchronous handler returning `ToolResultObject`
- `DefineTool.simple(...)` -- async handler returning `Future[String]`
- `DefineTool.simpleSync(...)` -- synchronous handler returning `String`

### Session Configuration

```scala
val config = SessionConfig(
  model = Some("gpt-4"),
  reasoningEffort = Some(ReasoningEffort.High),
  tools = List(myTool),
  systemMessage = Some(SystemMessageConfig.append("You are a helpful assistant.")),
  streaming = Some(true),
  workingDirectory = Some("/my/project"),
  onPermissionRequest = Some { (request, inv) =>
    Future.successful(PermissionRequestResult(kind = PermissionRequestResult.Approved))
  },
  onUserInputRequest = Some { (request, inv) =>
    Future.successful(UserInputResponse(answer = "yes", wasFreeform = true))
  },
  hooks = Some(SessionHooks(
    onPreToolUse = Some { (input, inv) =>
      Future.successful(Some(PreToolUseHookOutput(
        permissionDecision = Some("allow")
      )))
    }
  ))
)
```

### Session Events

Events are delivered as `SessionEvent` instances with a `type` discriminator:

```scala
session.on { event =>
  event.`type` match
    case SessionEventType.AssistantMessage =>
      val content = event.data.hcursor.get[String]("content").getOrElse("")
      println(s"Assistant: $content")
    case SessionEventType.SessionIdle =>
      println("Session is idle")
    case SessionEventType.SessionError =>
      val msg = event.data.hcursor.get[String]("message").getOrElse("")
      println(s"Error: $msg")
    case _ => ()
}
```

### Connecting to an Existing Server

```scala
val client = CopilotClient(CopilotClientOptions(
  cliUrl = Some("localhost:3000")
))
```

### Custom Providers (BYOK)

```scala
val config = SessionConfig(
  provider = Some(ProviderConfig(
    baseUrl = "https://api.openai.com/v1",
    apiKey = Some("sk-..."),
    `type` = Some("openai")
  ))
)
```

### MCP Servers

```scala
val config = SessionConfig(
  mcpServers = Some(Map(
    "my-server" -> MCPServerConfig.local(
      command = "node",
      args = List("server.js"),
      tools = List("*")
    ),
    "remote-server" -> MCPServerConfig.remote(
      url = "https://mcp.example.com",
      `type` = "http"
    )
  ))
)
```

## Protocol Version

The SDK verifies protocol version compatibility on connect. The current version is **2** (defined in `SdkProtocolVersion.scala`). If the server reports a different version, the client throws an error.

## Error Handling

- JSON-RPC errors are raised as `JsonRpcException` containing the error code and message
- Tool handler errors are caught and returned as `failure` results to the LLM
- Permission handler errors default to denying the permission
- Hook handler errors are silently ignored (hooks are best-effort)

## Running the Example

```bash
cd copilot-sdk/scala
sbt "runMain BasicExample"
```

## License

See [LICENSE](../LICENSE) in the repository root.
