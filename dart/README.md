# Copilot Supercharged SDK for Dart

Dart SDK for programmatic control of GitHub Copilot CLI via JSON-RPC 2.0.

This SDK follows the same architecture and protocol as the official Node.js, Python, Go, and .NET SDKs in the [copilot-sdk-supercharged](https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged) repository.

## Features

- Spawn and manage the Copilot CLI server process
- Communicate over **stdio** (default) or **TCP** transport
- JSON-RPC 2.0 with Content-Length header framing (LSP-style)
- Create, resume, list, and delete conversation sessions
- Stream session events via Dart `Stream<Map<String, dynamic>>`
- Register custom tools with JSON Schema parameters
- Handle permission requests, user input requests, and lifecycle hooks
- `sendAndWait` convenience method that blocks until `session.idle`
- Protocol version verification on connect
- Models listing with caching
- Full null safety

## Requirements

- Dart SDK >= 3.0.0
- GitHub Copilot CLI installed and accessible

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  copilot_sdk_supercharged:
    path: ../dart  # or publish to pub.dev
```

Then run:

```bash
dart pub get
```

## Quick Start

```dart
import 'package:copilot_sdk/copilot_sdk.dart';

void main() async {
  // Create a client that spawns the CLI server.
  final client = CopilotClient(CopilotClientOptions(
    cliPath: '/path/to/copilot-cli',
  ));

  await client.start();

  // Create a session.
  final session = await client.createSession(SessionConfig(
    model: 'gpt-4o',
  ));

  // Listen for events.
  session.events.listen((event) {
    if (event['type'] == 'assistant.message') {
      print(event['data']['content']);
    }
  });

  // Send a message and wait for the full response.
  final response = await session.sendAndWait(
    MessageOptions(prompt: 'Explain async/await in Dart'),
  );

  print(response?['data']?['content']);

  // Clean up.
  await session.destroy();
  await client.stop();
}
```

## Architecture

```
+------------------+       JSON-RPC 2.0        +------------------+
|                  |  Content-Length framing     |                  |
|  CopilotClient   | <-----------------------> |  Copilot CLI     |
|  (Dart process)  |   stdio or TCP pipes       |  (server)        |
|                  |                            |                  |
+------------------+                            +------------------+
        |
        +-- CopilotSession (1 per conversation)
              |
              +-- events: Stream<Map<String, dynamic>>
              +-- send() / sendAndWait()
              +-- tools, permissions, hooks
```

### Transport

The client communicates with the Copilot CLI server using JSON-RPC 2.0 messages framed with `Content-Length` headers, identical to the Language Server Protocol:

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"ping","params":{"message":"hello"}}
```

### Message Flow

1. **Client -> Server (requests):** `ping`, `session.create`, `session.send`, `session.destroy`, `models.list`, etc.
2. **Server -> Client (notifications):** `session.event` (with session events like `assistant.message`, `session.idle`), `session.lifecycle`
3. **Server -> Client (reverse requests):** `tool.call`, `permission.request`, `userInput.request`, `hooks.invoke`

## Custom Tools

Register tools that the Copilot agent can invoke:

```dart
final myTool = defineTool(
  'search_database',
  description: 'Search the product database',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'Search query'},
      'limit': {'type': 'integer', 'description': 'Max results'},
    },
    'required': ['query'],
  },
  handler: (args, invocation) async {
    final query = (args as Map)['query'] as String;
    final limit = (args as Map)['limit'] as int? ?? 10;
    // Perform search...
    return {'results': [], 'total': 0};
  },
);

final session = await client.createSession(SessionConfig(
  tools: [myTool],
));
```

### Structured Tool Results

For fine-grained control, return a `ToolResultObject`:

```dart
handler: (args, invocation) async {
  return ToolResultObject(
    textResultForLlm: 'Found 3 matching products',
    resultType: ToolResultType.success,
    toolTelemetry: {'queryTimeMs': 42},
  );
},
```

## Permission Handling

Control what operations the agent can perform:

```dart
final session = await client.createSession(SessionConfig(
  onPermissionRequest: (request, context) async {
    // request.kind is one of: shell, write, mcp, read, url
    if (request.kind == 'read') {
      return PermissionRequestResult(kind: 'approved');
    }
    return PermissionRequestResult(
      kind: 'denied-interactively-by-user',
    );
  },
));
```

## User Input

Allow the agent to ask the user questions:

```dart
final session = await client.createSession(SessionConfig(
  onUserInputRequest: (request, context) async {
    print('Agent asks: ${request.question}');
    // Get answer from user...
    return UserInputResponse(answer: 'Yes', wasFreeform: true);
  },
));
```

## Hooks

Intercept session lifecycle events:

```dart
final session = await client.createSession(SessionConfig(
  hooks: SessionHooks(
    onPreToolUse: (input, context) async {
      print('About to run: ${input.toolName}');
      // Return null for default behavior, or modify:
      return PreToolUseHookOutput(permissionDecision: 'allow');
    },
    onPostToolUse: (input, context) async {
      print('Finished: ${input.toolName}');
      return null;
    },
    onSessionStart: (input, context) async {
      print('Session started');
      return null;
    },
    onSessionEnd: (input, context) async {
      print('Session ended: ${input.reason}');
      return null;
    },
  ),
));
```

## Event Types

The `session.events` stream delivers events matching the session event schema. Common event types:

| Event Type | Description |
|---|---|
| `session.start` | Session initialized |
| `session.resume` | Session resumed |
| `session.idle` | Processing complete |
| `session.error` | Error occurred |
| `user.message` | User message sent |
| `assistant.message` | Full assistant response |
| `assistant.message_delta` | Streaming response chunk |
| `assistant.reasoning` | Model reasoning output |
| `tool.execution_start` | Tool invocation started |
| `tool.execution_complete` | Tool invocation finished |
| `session.shutdown` | Session shutting down |

## Session Management

```dart
// List all sessions.
final sessions = await client.listSessions();

// Resume a previous session.
final session = await client.resumeSession('session-id-here');

// Get the most recent session.
final lastId = await client.getLastSessionId();

// Delete a session permanently.
await client.deleteSession('session-id-here');
```

## Custom Providers (BYOK)

Use your own API endpoint:

```dart
final session = await client.createSession(SessionConfig(
  provider: ProviderConfig(
    type: 'openai',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'your-api-key',
  ),
));
```

## MCP Servers

Connect to Model Context Protocol servers:

```dart
final session = await client.createSession(SessionConfig(
  mcpServers: {
    'my-server': MCPLocalServerConfig(
      tools: ['*'],
      command: 'node',
      args: ['./my-mcp-server.js'],
    ),
  },
));
```

## Connecting to an External Server

Instead of spawning a CLI process, connect to an already-running server:

```dart
final client = CopilotClient(CopilotClientOptions(
  cliUrl: 'localhost:3000',
));

await client.start();
```

## Protocol Version

The SDK verifies protocol compatibility on connect via the `ping` response.
The current SDK protocol version is **2** (matching `sdk-protocol-version.json`).

## API Reference

### CopilotClient

| Method | Description |
|---|---|
| `start()` | Connect to CLI server |
| `stop()` | Graceful shutdown |
| `forceStop()` | Forceful shutdown |
| `createSession([config])` | Create a new session |
| `resumeSession(id, [config])` | Resume existing session |
| `deleteSession(id)` | Delete session from disk |
| `listSessions()` | List all sessions |
| `getLastSessionId()` | Get most recent session ID |
| `ping([message])` | Verify connectivity |
| `getStatus()` | Get CLI version info |
| `getAuthStatus()` | Get auth status |
| `listModels()` | List available models |
| `onLifecycle(handler)` | Subscribe to lifecycle events |

### CopilotSession

| Method / Property | Description |
|---|---|
| `sessionId` | Session identifier |
| `workspacePath` | Workspace directory path |
| `events` | Broadcast stream of all events |
| `on(eventType)` | Filtered event stream |
| `send(options)` | Send a message |
| `sendAndWait(options)` | Send and wait for idle |
| `getMessages()` | Get conversation history |
| `abort()` | Abort current processing |
| `destroy()` | Destroy the session |

## License

See [LICENSE](../LICENSE) in the repository root.
