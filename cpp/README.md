# Copilot Supercharged SDK for C++

C++ SDK for the GitHub Copilot CLI. Communicates with the Copilot CLI server via JSON-RPC 2.0 over stdio pipes using Content-Length header framing.

## Requirements

- C++17 compatible compiler (GCC 8+, Clang 7+, MSVC 2019+)
- CMake 3.16+
- [nlohmann/json](https://github.com/nlohmann/json) (automatically fetched via CMake FetchContent)
- [GitHub Copilot CLI](https://github.com/github/copilot) installed and available on PATH (or specify path via `CopilotClientOptions::cliPath`)

## Building

```bash
mkdir build && cd build
cmake ..
cmake --build .
```

To disable building examples:

```bash
cmake .. -DCOPILOT_SDK_BUILD_EXAMPLES=OFF
```

## Quick Start

```cpp
#include <copilot/client.h>
#include <copilot/define_tool.h>
#include <copilot/types.h>
#include <iostream>

int main() {
    // Create and start client
    copilot::CopilotClient client;
    client.start();

    // Create a session
    auto session = client.createSession();

    // Subscribe to events
    session->on([](const copilot::SessionEvent& event) {
        if (event.type == "assistant.message") {
            std::cout << event.data.value("content", "") << std::endl;
        }
    });

    // Send a message and wait for completion
    auto response = session->sendAndWait({"What is 2+2?"});

    // Clean up
    session->destroy();
    client.stop();
    return 0;
}
```

## Architecture

The SDK mirrors the architecture of the official Node.js, Python, Go, and .NET SDKs:

```
CopilotClient
  |-- Spawns CLI process (copilot --headless --no-auto-update --log-level info --stdio)
  |-- JsonRpcClient (Content-Length framed JSON-RPC 2.0 over pipes)
  |     |-- Reader thread (reads from CLI stdout)
  |     |-- Pending requests (std::promise/future)
  |     |-- Request handlers (for server->client calls)
  |-- Sessions (CopilotSession)
        |-- Event handlers (wildcard and typed)
        |-- Tool handlers
        |-- Permission handler
        |-- User input handler
        |-- Hook handlers
```

### Transport Protocol

Messages are framed using the LSP base protocol:

```
Content-Length: <byte-count>\r\n
\r\n
<JSON-RPC message>
```

### JSON-RPC Methods

**Client -> Server (requests):**
- `ping` - Verify connectivity and protocol version
- `status.get` - Get CLI version info
- `auth.getStatus` - Get authentication status
- `models.list` - List available models
- `session.create` - Create a new session
- `session.resume` - Resume an existing session
- `session.send` - Send a message to a session
- `session.getMessages` - Get session history
- `session.destroy` - Destroy a session
- `session.abort` - Abort current processing
- `session.delete` - Delete a session permanently
- `session.list` - List all sessions
- `session.getLastId` - Get the last session ID
- `session.getForeground` - Get foreground session (TUI mode)
- `session.setForeground` - Set foreground session (TUI mode)

**Server -> Client (notifications):**
- `session.event` - Session events (assistant.message, session.idle, etc.)
- `session.lifecycle` - Session lifecycle events (created, deleted, etc.)

**Server -> Client (requests):**
- `tool.call` - Execute a registered tool
- `permission.request` - Request permission for an operation
- `userInput.request` - Request input from the user
- `hooks.invoke` - Invoke a hook handler

## API Reference

### CopilotClient

The main entry point. Manages the CLI server connection and session lifecycle.

```cpp
copilot::CopilotClientOptions options;
options.cliPath = "/usr/local/bin/copilot";
options.logLevel = "debug";

copilot::CopilotClient client(options);
client.start();

// ... use sessions ...

client.stop();
```

### CopilotSession

Represents a conversation session.

```cpp
// Create with configuration
copilot::SessionConfig config;
config.model = "gpt-4";
config.tools = {myTool};
config.streaming = true;

auto session = client.createSession(config);

// Subscribe to specific event types
auto id = session->on("assistant.message", [](const copilot::SessionEvent& event) {
    std::cout << event.data.value("content", "") << std::endl;
});

// Send and wait
auto response = session->sendAndWait({"Hello!"}, 30000); // 30s timeout

// Unsubscribe
session->off(id);

// Clean up
session->destroy();
```

### Tools

Define custom tools that the assistant can invoke:

```cpp
auto tool = copilot::defineTool(
    "calculate",
    "Perform a calculation",
    nlohmann::json::parse(R"({
        "type": "object",
        "properties": {
            "expression": {"type": "string"}
        },
        "required": ["expression"]
    })"),
    [](const nlohmann::json& args, const copilot::ToolInvocation& inv)
        -> copilot::ToolResultObject {
        std::string expr = args.value("expression", "");
        // ... evaluate expression ...
        return copilot::toolSuccess("Result: 42");
    });
```

Helper functions for tool results:
- `copilot::toolSuccess(text)` - Create a successful result
- `copilot::toolFailure(message, error)` - Create a failed result
- `copilot::toolSuccessJson(json)` - Create a successful result from JSON

### Permissions

Handle permission requests from the assistant:

```cpp
config.onPermissionRequest = [](const copilot::PermissionRequest& req,
                                const std::string& sessionId)
    -> copilot::PermissionRequestResult {
    if (req.kind == "read") {
        return {"approved"};
    }
    return {"denied-interactively-by-user"};
};
```

### User Input

Handle user input requests (enables the ask_user tool):

```cpp
config.onUserInputRequest = [](const copilot::UserInputRequest& req,
                               const std::string& sessionId)
    -> copilot::UserInputResponse {
    std::cout << "Agent asks: " << req.question << std::endl;
    std::string answer;
    std::getline(std::cin, answer);
    return {answer, true};
};
```

### Hooks

Intercept session lifecycle events:

```cpp
copilot::SessionHooks hooks;
hooks.onPreToolUse = [](const copilot::PreToolUseHookInput& input,
                        const std::string& sessionId)
    -> std::optional<copilot::PreToolUseHookOutput> {
    std::cout << "About to use tool: " << input.toolName << std::endl;
    return copilot::PreToolUseHookOutput{.permissionDecision = "allow"};
};

config.hooks = hooks;
```

### Session Lifecycle Events

Monitor session lifecycle at the client level:

```cpp
auto unsub = client.onLifecycle("session.created",
    [](const copilot::SessionLifecycleEvent& event) {
        std::cout << "Session created: " << event.sessionId << std::endl;
    });

// Later: unsub() to unsubscribe
```

### BYOK (Bring Your Own Key)

Use a custom model provider:

```cpp
copilot::SessionConfig config;
config.provider = copilot::ProviderConfig{
    .type = "openai",
    .baseUrl = "https://api.openai.com/v1",
    .apiKey = "sk-..."
};
config.model = "gpt-4";
```

### MCP Servers

Configure MCP (Model Context Protocol) servers:

```cpp
config.mcpServers = std::map<std::string, copilot::MCPServerConfig>{
    {"my-server", nlohmann::json{
        {"command", "node"},
        {"args", {"./mcp-server.js"}},
        {"tools", {"*"}}
    }}
};
```

## Thread Safety

- All public methods on `CopilotClient` and `CopilotSession` are thread-safe.
- Event handlers are called from the JSON-RPC reader thread (for notifications) or from
  detached threads (for request handlers). Handlers should be thread-safe.
- The `sendAndWait` method uses `std::condition_variable` internally and is safe to call
  from any thread.

## Protocol Version

The SDK verifies protocol compatibility on connection. The expected protocol version is
defined in `copilot/sdk_protocol_version.h`. If the server reports a different version,
an error is thrown during `start()`.

## Platform Support

- Linux (GCC, Clang)
- macOS (Clang)
- Windows (MSVC) - Uses Win32 `CreateProcess` and pipe APIs

## License

See the LICENSE file in the repository root.
