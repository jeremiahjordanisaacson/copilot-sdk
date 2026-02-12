# GitHub Copilot Supercharged PHP SDK

PHP SDK for the GitHub Copilot CLI. Communicates with the Copilot CLI server via JSON-RPC 2.0 over stdio or TCP.

## Requirements

- PHP 8.1 or later
- The GitHub Copilot CLI installed and accessible on PATH (or provide a custom path)
- A valid GitHub Copilot subscription

## Installation

```bash
composer require github/copilot-sdk-supercharged
```

Or add to your `composer.json`:

```json
{
    "require": {
        "github/copilot-sdk-supercharged": "*"
    }
}
```

## Quick Start

```php
<?php

require_once 'vendor/autoload.php';

use GitHub\Copilot\CopilotClient;
use GitHub\Copilot\MessageOptions;
use GitHub\Copilot\SessionConfig;
use GitHub\Copilot\SessionEvent;

// Create and start client
$client = new CopilotClient();
$client->start();

// Create a session
$session = $client->createSession(new SessionConfig(
    model: 'gpt-4',
));

// Listen for events
$session->on(function (SessionEvent $event) {
    if ($event->type === 'assistant.message') {
        echo $event->data['content'] ?? '';
    }
});

// Send a message and wait for the response
$response = $session->sendAndWait(new MessageOptions(
    prompt: 'Explain what PHP generics would look like.',
));

echo $response?->data['content'] ?? 'No response';

// Clean up
$session->destroy();
$client->stop();
```

## Architecture

The SDK follows the same patterns as the official Node.js, Python, Go, and .NET SDKs:

```
CopilotClient
  |-- spawns CLI process (--headless --no-auto-update --stdio)
  |-- JsonRpcClient (Content-Length header framing)
  |     |-- sends requests (session.create, session.send, ping, etc.)
  |     |-- receives notifications (session.event, session.lifecycle)
  |     |-- handles server requests (tool.call, permission.request, etc.)
  |-- CopilotSession[]
        |-- event handlers
        |-- tool handlers
        |-- permission / user input / hooks handlers
```

### Protocol

Messages use JSON-RPC 2.0 with Content-Length header framing (Language Server Protocol style):

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
```

The SDK protocol version (currently `2`) is verified on startup via the ping response.

## API Reference

### CopilotClient

The main entry point. Manages the connection to the CLI server and provides session management.

```php
use GitHub\Copilot\CopilotClient;
use GitHub\Copilot\CopilotClientOptions;
use GitHub\Copilot\LogLevel;

// Default options - spawns CLI server using stdio
$client = new CopilotClient();

// Custom options
$client = new CopilotClient(new CopilotClientOptions(
    cliPath: '/usr/local/bin/copilot',
    logLevel: LogLevel::Debug,
    useStdio: true,
));

// Connect to an existing server
$client = new CopilotClient(new CopilotClientOptions(
    cliUrl: 'localhost:3000',
));

// Authenticate with a token
$client = new CopilotClient(new CopilotClientOptions(
    githubToken: 'ghp_...',
));
```

#### Methods

| Method | Description |
|--------|-------------|
| `start()` | Start the CLI server and connect |
| `stop(): string[]` | Gracefully stop, returns any cleanup errors |
| `forceStop()` | Force stop without cleanup |
| `createSession(SessionConfig): CopilotSession` | Create a new session |
| `resumeSession(string, ResumeSessionConfig): CopilotSession` | Resume existing session |
| `getState(): ConnectionState` | Get connection state |
| `ping(string): PingResponse` | Ping the server |
| `getStatus(): GetStatusResponse` | Get CLI version/protocol info |
| `getAuthStatus(): GetAuthStatusResponse` | Get authentication status |
| `listModels(): ModelInfo[]` | List available models (cached) |
| `getLastSessionId(): ?string` | Get most recent session ID |
| `deleteSession(string)` | Delete a session from disk |
| `listSessions(): SessionMetadata[]` | List all sessions |
| `getForegroundSessionId(): ?string` | Get foreground session (TUI mode) |
| `setForegroundSessionId(string)` | Set foreground session (TUI mode) |
| `onLifecycle(callable): callable` | Subscribe to all lifecycle events |
| `onLifecycleEvent(string, callable): callable` | Subscribe to specific lifecycle event |
| `processMessages(float)` | Process pending server messages |

### CopilotSession

Represents a conversation session. Created via `CopilotClient::createSession()`.

```php
use GitHub\Copilot\SessionConfig;
use GitHub\Copilot\MessageOptions;

$session = $client->createSession(new SessionConfig(
    model: 'gpt-4',
    tools: [$myTool],
    streaming: true,
    workingDirectory: '/path/to/project',
));
```

#### Methods

| Method | Description |
|--------|-------------|
| `send(MessageOptions): string` | Send a message, returns message ID |
| `sendAndWait(MessageOptions, float): ?SessionEvent` | Send and wait for idle |
| `on(callable): callable` | Subscribe to all events |
| `onEvent(string, callable): callable` | Subscribe to specific event type |
| `getMessages(): SessionEvent[]` | Get conversation history |
| `destroy()` | Destroy the session |
| `abort()` | Abort current processing |

#### Session Events

Events received from the server include:

| Event Type | Description |
|------------|-------------|
| `assistant.message` | Final assistant response |
| `assistant.message_delta` | Streaming response chunk |
| `assistant.reasoning_delta` | Streaming reasoning chunk |
| `session.idle` | Session finished processing |
| `session.error` | Session error |
| `session.resume` | Session resumed |
| `tool.executing` | Tool execution started |
| `tool.completed` | Tool execution completed |

### Defining Tools

Tools allow the LLM to call custom functions. Use the `DefineTool` builder:

```php
use GitHub\Copilot\DefineTool;
use GitHub\Copilot\ToolInvocation;

// Builder pattern
$tool = DefineTool::create('get_weather')
    ->description('Get weather for a location')
    ->parameters([
        'type' => 'object',
        'properties' => [
            'location' => [
                'type' => 'string',
                'description' => 'City name',
            ],
        ],
        'required' => ['location'],
    ])
    ->handler(function (mixed $args, ToolInvocation $invocation): string {
        return "Sunny, 72F in {$args['location']}";
    })
    ->build();

// Simple helper
$tool = DefineTool::simple(
    name: 'get_weather',
    description: 'Get weather for a location',
    parameters: [...],
    handler: fn($args) => "Sunny, 72F",
);
```

Tool handlers can return:
- `string` - wrapped as a successful result
- `ToolResultObject` - passed through directly
- `array` with `textResultForLlm` + `resultType` - passed through
- Any other value - JSON-encoded as success
- Exceptions are caught and returned as failure results (details hidden from LLM)

### Permission Handling

When the agent needs permission for operations (file writes, shell commands, etc.):

```php
use GitHub\Copilot\PermissionRequest;
use GitHub\Copilot\PermissionRequestResult;

$session = $client->createSession(new SessionConfig(
    onPermissionRequest: function (PermissionRequest $request, array $context): PermissionRequestResult {
        // Auto-approve reads, deny everything else
        if ($request->kind === 'read') {
            return new PermissionRequestResult(kind: 'approved');
        }
        return new PermissionRequestResult(kind: 'denied-interactively-by-user');
    },
));
```

Permission result kinds:
- `approved`
- `denied-by-rules`
- `denied-no-approval-rule-and-could-not-request-from-user`
- `denied-interactively-by-user`

### User Input Handling

Enable the `ask_user` tool so the agent can ask questions:

```php
use GitHub\Copilot\UserInputRequest;
use GitHub\Copilot\UserInputResponse;

$session = $client->createSession(new SessionConfig(
    onUserInputRequest: function (UserInputRequest $request, array $context): UserInputResponse {
        echo "Agent asks: {$request->question}\n";
        $answer = readline('> ');
        return new UserInputResponse(answer: $answer, wasFreeform: true);
    },
));
```

### Session Hooks

Hooks allow intercepting session lifecycle events:

```php
use GitHub\Copilot\SessionHooks;

$session = $client->createSession(new SessionConfig(
    hooks: new SessionHooks(
        onPreToolUse: function (mixed $input, array $context): ?array {
            echo "About to use tool: {$input['toolName']}\n";
            return ['permissionDecision' => 'allow'];
        },
        onPostToolUse: function (mixed $input, array $context): ?array {
            echo "Tool completed: {$input['toolName']}\n";
            return null;
        },
        onSessionStart: function (mixed $input, array $context): ?array {
            echo "Session started\n";
            return null;
        },
    ),
));
```

### MCP Server Configuration

Add MCP (Model Context Protocol) servers to a session:

```php
use GitHub\Copilot\MCPLocalServerConfig;
use GitHub\Copilot\MCPRemoteServerConfig;

$session = $client->createSession(new SessionConfig(
    mcpServers: [
        'my-local-server' => new MCPLocalServerConfig(
            tools: ['*'],
            command: 'node',
            args: ['./my-mcp-server.js'],
        ),
        'my-remote-server' => new MCPRemoteServerConfig(
            tools: ['tool1', 'tool2'],
            type: 'http',
            url: 'https://my-mcp-server.example.com',
        ),
    ],
));
```

### Custom Providers (BYOK)

Use your own API endpoint instead of the Copilot API:

```php
use GitHub\Copilot\ProviderConfig;

$session = $client->createSession(new SessionConfig(
    provider: new ProviderConfig(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-...',
        type: 'openai',
    ),
));
```

### Session Lifecycle Events

Monitor session creation, deletion, and state changes (useful in TUI+server mode):

```php
// All lifecycle events
$unsubscribe = $client->onLifecycle(function ($event) {
    echo "Lifecycle: {$event->type} for session {$event->sessionId}\n";
});

// Specific event type
$unsubscribe = $client->onLifecycleEvent('session.created', function ($event) {
    echo "New session: {$event->sessionId}\n";
});

// Unsubscribe when done
$unsubscribe();
```

## Transport Modes

### stdio (default)

The SDK spawns the CLI process and communicates via stdin/stdout pipes. This is the recommended mode.

```php
$client = new CopilotClient(new CopilotClientOptions(
    useStdio: true, // default
));
```

### TCP

The SDK spawns the CLI process with a TCP port, or connects to an existing server.

```php
// Spawn with random port
$client = new CopilotClient(new CopilotClientOptions(
    useStdio: false,
    port: 0, // random
));

// Connect to existing server
$client = new CopilotClient(new CopilotClientOptions(
    cliUrl: 'localhost:3000',
));
```

## Event Loop

Since PHP is synchronous, the SDK uses blocking I/O with timeouts. The `sendAndWait()` method processes messages in a loop until the session becomes idle.

If you need to process events outside of `sendAndWait()`, call `processMessages()` periodically:

```php
// Send without waiting
$messageId = $session->send(new MessageOptions(prompt: 'Hello'));

// Manually process events
while (true) {
    $client->processMessages(0.1); // Process for up to 100ms
    // Your other logic here...
}
```

## File Structure

```
php/
  composer.json              # Composer package configuration
  README.md                  # This file
  src/
    SdkProtocolVersion.php   # Protocol version constant
    Types.php                # All type definitions
    JsonRpcClient.php        # JSON-RPC 2.0 client
    CopilotClient.php        # Main client class
    CopilotSession.php       # Session class
    DefineTool.php           # Tool definition helper
  examples/
    basic_example.php        # Full working example
```

## License

MIT - Copyright (c) Microsoft Corporation. All rights reserved.
