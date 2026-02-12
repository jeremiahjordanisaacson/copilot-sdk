# Copilot SDK for Lua

A Lua SDK for interacting with the GitHub Copilot CLI server. Communicates via JSON-RPC 2.0 over stdio using Content-Length header framing.

## Requirements

- Lua 5.1+ (tested with 5.1, 5.2, 5.3, 5.4, and LuaJIT)
- [lua-cjson](https://www.kyne.com.au/~mark/software/lua-cjson.php) for JSON encoding/decoding
- The `copilot` CLI installed and available on `PATH` (or specify the path via `cliPath`)

## Installation

### Via LuaRocks

```bash
luarocks install copilot-sdk
```

### Manual

Copy the `copilot/` directory into your Lua module path.

## Quick Start

```lua
local CopilotClient = require("copilot.client")
local define_tool   = require("copilot.define_tool")

-- Create and start the client
local client = CopilotClient.new({ logLevel = "info" })
local ok, err = client:start()
if not ok then
    error("Failed to start: " .. tostring(err))
end

-- Create a session
local session, err = client:create_session()
if not session then
    error("Failed to create session: " .. tostring(err))
end

-- Listen to events
local unsubscribe = session:on(function(event)
    print(event.type, event.data and event.data.content)
end)

-- Send a message and wait for the response
local response, err = session:send_and_wait({ prompt = "What is 2+2?" })
if response then
    print("Answer:", response.data.content)
end

-- Clean up
unsubscribe()
session:destroy()
client:stop()
```

## Architecture

The SDK follows the same architecture as the Node.js, Python, Go, and .NET SDKs:

```
CopilotClient (client.lua)
    |
    |-- spawns CLI process with --headless --no-auto-update --stdio
    |-- manages JsonRpcClient for communication
    |-- dispatches incoming server requests to sessions
    |
    +-- CopilotSession (session.lua)
            |-- event subscriptions (on / unsubscribe)
            |-- send / send_and_wait
            |-- tool handlers
            |-- permission handler
            |-- user input handler
            |-- hooks (pre/post tool use, session start/end, etc.)
```

Communication uses **JSON-RPC 2.0** with **Content-Length header framing**:

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":"...","method":"...","params":{...}}
```

## Modules

| Module | Description |
|--------|-------------|
| `copilot.client` | `CopilotClient` -- manages CLI process and sessions |
| `copilot.session` | `CopilotSession` -- conversation session with event handling |
| `copilot.json_rpc_client` | `JsonRpcClient` -- JSON-RPC 2.0 over stdio transport |
| `copilot.types` | Type constructors and constants |
| `copilot.define_tool` | Helper for defining tools with result normalization |
| `copilot.sdk_protocol_version` | Protocol version constant (must match server) |

## Custom Tools

Define tools that the Copilot agent can invoke:

```lua
local define_tool = require("copilot.define_tool")

local weather_tool = define_tool("get_weather", {
    description = "Get current weather for a city",
    parameters = {
        type = "object",
        properties = {
            city = { type = "string", description = "City name" },
            unit = {
                type = "string",
                enum = { "celsius", "fahrenheit" },
                description = "Temperature unit",
            },
        },
        required = { "city" },
    },
    handler = function(args, invocation)
        -- args.city, args.unit are parsed from the JSON arguments
        -- invocation has sessionId, toolCallId, toolName, arguments
        return string.format("Weather in %s: 22 degrees %s",
            args.city, args.unit or "celsius")
    end,
})

local session = client:create_session({
    tools = { weather_tool },
})
```

The handler can return:

- A **string** -- becomes `textResultForLlm` with `resultType = "success"`
- A **ToolResult table** -- passed through directly
- A **table** -- JSON-serialized to `textResultForLlm`
- **nil** -- empty success result

If the handler raises an error, a failure `ToolResult` is returned automatically.

## Permission Handling

Register a handler to approve or deny tool permission requests:

```lua
local types = require("copilot.types")

local session = client:create_session({
    onPermissionRequest = function(request, invocation)
        print("Permission requested:", request.kind)
        -- Return approval
        return types.PermissionRequestResult({ kind = "approved" })
    end,
})
```

## User Input Handling

Register a handler to respond to user input requests (enables the `ask_user` tool):

```lua
local types = require("copilot.types")

local session = client:create_session({
    onUserInputRequest = function(request, invocation)
        print("Question:", request.question)
        -- Return a response
        return types.UserInputResponse({
            answer      = "Yes, proceed.",
            wasFreeform = true,
        })
    end,
})
```

## Hooks

Register lifecycle hooks for observability and customization:

```lua
local session = client:create_session({
    hooks = {
        onPreToolUse = function(input, invocation)
            print("About to use tool:", input.toolName)
            return { permissionDecision = "allow" }
        end,
        onPostToolUse = function(input, invocation)
            print("Tool completed:", input.toolName)
            return nil
        end,
        onSessionStart = function(input, invocation)
            print("Session started, source:", input.source)
            return nil
        end,
        onSessionEnd = function(input, invocation)
            print("Session ended, reason:", input.reason)
            return nil
        end,
    },
})
```

Available hooks:
- `onPreToolUse` -- before a tool is executed
- `onPostToolUse` -- after a tool completes
- `onUserPromptSubmitted` -- when the user submits a prompt
- `onSessionStart` -- when a session starts
- `onSessionEnd` -- when a session ends
- `onErrorOccurred` -- when an error occurs

## Client Options

```lua
local client = CopilotClient.new({
    cliPath         = "/usr/local/bin/copilot",  -- default: "copilot"
    cwd             = "/path/to/project",         -- working directory
    logLevel        = "debug",                    -- "info", "debug", "warn", "error"
    githubToken     = "ghp_...",                  -- GitHub auth token
    useLoggedInUser = true,                       -- use stored OAuth tokens
    autoStart       = true,                       -- auto-start on first use
    autoRestart     = true,                       -- restart if CLI crashes
})
```

## Session Configuration

```lua
local session = client:create_session({
    model               = "gpt-4",
    reasoningEffort     = "medium",            -- "low", "medium", "high", "xhigh"
    tools               = { my_tool },
    systemMessage       = { mode = "append", content = "Extra instructions" },
    availableTools      = { "Read", "Write" }, -- allowlist
    excludedTools       = { "Bash" },          -- blocklist (ignored if availableTools set)
    workingDirectory    = "/path/to/project",
    streaming           = true,                -- enable streaming deltas
    onPermissionRequest = my_permission_handler,
    onUserInputRequest  = my_input_handler,
    hooks               = my_hooks,
    provider            = {                    -- BYOK
        type    = "openai",
        baseUrl = "https://api.example.com/v1",
        apiKey  = "sk-...",
    },
    mcpServers = {
        myServer = {
            type    = "local",
            command = "node",
            args    = { "server.js" },
            tools   = { "tool1", "tool2" },
        },
    },
    infiniteSessions = {
        enabled = true,
        backgroundCompactionThreshold = 0.80,
        bufferExhaustionThreshold     = 0.95,
    },
})
```

## Session Event Types

All event type constants are available in `types.SessionEventType`:

```lua
local types = require("copilot.types")

session:on(function(event)
    if event.type == types.SessionEventType.ASSISTANT_MESSAGE then
        print(event.data.content)
    elseif event.type == types.SessionEventType.SESSION_IDLE then
        print("Session is idle")
    elseif event.type == types.SessionEventType.TOOL_EXECUTION_COMPLETE then
        print("Tool finished:", event.data.toolName)
    end
end)
```

## Protocol Version

The SDK protocol version must match the server. The current version is **2**.

```lua
local version = require("copilot.sdk_protocol_version")
print(version.get())  -- 2
```

The client automatically verifies protocol compatibility on startup via the `ping` response.

## API Reference

### CopilotClient

| Method | Description |
|--------|-------------|
| `CopilotClient.new(options)` | Create a new client |
| `client:start()` | Start CLI server and connect |
| `client:stop()` | Stop server and clean up |
| `client:state()` | Get connection state |
| `client:ping(message)` | Ping server |
| `client:get_status()` | Get server status |
| `client:get_auth_status()` | Get auth status |
| `client:list_models()` | List available models (cached) |
| `client:create_session(config)` | Create a new session |
| `client:resume_session(id, config)` | Resume an existing session |
| `client:list_sessions()` | List all sessions |
| `client:delete_session(id)` | Delete a session |
| `client:get_foreground_session_id()` | Get TUI foreground session |
| `client:set_foreground_session_id(id)` | Set TUI foreground session |

### CopilotSession

| Method | Description |
|--------|-------------|
| `session:send(options)` | Send a message |
| `session:send_and_wait(options, timeout)` | Send and wait for idle |
| `session:on(handler)` | Subscribe to events (returns unsubscribe fn) |
| `session:get_messages()` | Get conversation history |
| `session:destroy()` | Destroy the session |
| `session:abort()` | Abort current message processing |

### define_tool

```lua
local tool = define_tool(name, { description, parameters, handler })
```

## License

MIT
