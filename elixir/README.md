# Copilot SDK for Elixir

Elixir SDK for the [GitHub Copilot CLI](https://github.com/github/copilot-sdk). Communicates with the Copilot CLI server via JSON-RPC 2.0 over stdio.

## Requirements

- Elixir 1.15+
- The `copilot` CLI installed and on your PATH (or specify the path via `:cli_path`)
- Authenticated via `copilot auth login`

## Installation

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:copilot_sdk, path: "../elixir"}  # or from Hex when published
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

```elixir
alias Copilot.Client
alias Copilot.Session
alias Copilot.DefineTool
alias Copilot.Types.{CopilotClientOptions, SessionConfig, MessageOptions}

# Start the client (spawns the CLI process automatically)
{:ok, client} = Client.start_link(%CopilotClientOptions{log_level: "info"})

# Create a session
{:ok, session} = Client.create_session(client, %SessionConfig{})

# Subscribe to events
Session.on(session, fn event ->
  if event["type"] == "assistant.message" do
    IO.puts("Assistant: " <> event["data"]["content"])
  end
end)

# Send a message and wait for the response
{:ok, response} = Session.send_and_wait(session, %MessageOptions{prompt: "What is 2+2?"})
IO.puts("Response: #{response["data"]["content"]}")

# Clean up
Session.destroy(session)
Client.stop(client)
```

## Architecture

The SDK consists of the following modules:

| Module | Description |
|---|---|
| `Copilot.Client` | Main client GenServer. Spawns the CLI process, manages the JSON-RPC connection, and provides session lifecycle operations (create, resume, delete, list). |
| `Copilot.Session` | Session GenServer. Sends messages, subscribes to events, handles tool calls, permissions, user input, and hooks. |
| `Copilot.JsonRpcClient` | Low-level JSON-RPC 2.0 client using Erlang `Port` for stdio communication with Content-Length header framing. |
| `Copilot.Types` | All type definitions as Elixir structs with typespecs. |
| `Copilot.DefineTool` | Helper for defining tools to expose to the CLI. |
| `Copilot.SdkProtocolVersion` | Protocol version constant (must match the server). |

## Defining Tools

Tools allow the assistant to call custom functions you define. Use `Copilot.DefineTool.define/2`:

```elixir
tool = Copilot.DefineTool.define("get_weather",
  description: "Get the current weather for a city.",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "city" => %{"type" => "string", "description" => "City name"}
    },
    "required" => ["city"]
  },
  handler: fn %{"city" => city}, _invocation ->
    "The weather in #{city} is sunny, 72F."
  end
)

{:ok, session} = Client.create_session(client, %SessionConfig{tools: [tool]})
```

The handler function receives two arguments:

1. The parsed arguments (a map matching your JSON schema)
2. A `Copilot.Types.ToolInvocation` struct with session context

It can return:
- A plain string (wrapped as a success result)
- A `Copilot.Types.ToolResult` struct (for full control)
- Any other term (JSON-encoded as a success result)

## Event Subscriptions

Subscribe to all events or specific event types:

```elixir
# All events
ref = Session.on(session, fn event -> IO.inspect(event) end)

# Specific event type
ref = Session.on(session, "assistant.message", fn event ->
  IO.puts(event["data"]["content"])
end)

# Unsubscribe
Session.off(session, ref)
```

### Common Event Types

| Event Type | Description |
|---|---|
| `session.start` | Session started |
| `session.idle` | Session finished processing |
| `session.error` | An error occurred |
| `user.message` | User message recorded |
| `assistant.message` | Final assistant response |
| `assistant.message_delta` | Streaming response chunk (when streaming enabled) |
| `tool.execution_start` | Tool execution started |
| `tool.execution_complete` | Tool execution finished |

## Permissions

Handle permission requests from the server:

```elixir
alias Copilot.Types.{PermissionRequest, PermissionRequestResult}

config = %SessionConfig{
  on_permission_request: fn %PermissionRequest{kind: kind}, _ctx ->
    IO.puts("Permission requested: #{kind}")
    %PermissionRequestResult{kind: :approved}
  end
}
```

## User Input (ask_user)

Handle user input requests from the agent:

```elixir
alias Copilot.Types.{UserInputRequest, UserInputResponse}

config = %SessionConfig{
  on_user_input_request: fn %UserInputRequest{question: q}, _ctx ->
    answer = IO.gets("#{q} > ") |> String.trim()
    %UserInputResponse{answer: answer, was_freeform: true}
  end
}
```

## Hooks

Intercept session lifecycle events with hooks:

```elixir
alias Copilot.Types.SessionHooks

config = %SessionConfig{
  hooks: %SessionHooks{
    on_pre_tool_use: fn input, _ctx ->
      IO.puts("About to use tool: #{input["toolName"]}")
      %{"permissionDecision" => "allow"}
    end,
    on_post_tool_use: fn input, _ctx ->
      IO.puts("Tool completed: #{input["toolName"]}")
      nil
    end
  }
}
```

## Session Management

```elixir
# List all sessions
{:ok, sessions} = Client.list_sessions(client)

# Resume a previous session
{:ok, session} = Client.resume_session(client, session_id)

# Delete a session
:ok = Client.delete_session(client, session_id)

# Get the last session ID
{:ok, last_id} = Client.get_last_session_id(client)

# List available models
{:ok, models} = Client.list_models(client)
```

## Custom Providers (BYOK)

Use your own API endpoint:

```elixir
alias Copilot.Types.ProviderConfig

config = %SessionConfig{
  provider: %ProviderConfig{
    type: "openai",
    base_url: "http://localhost:11434/v1",
    api_key: "ollama"
  },
  model: "llama3"
}
```

## Protocol Version

The SDK protocol version must match the CLI server's version. The current version is **2**. Version mismatches will produce a clear error message on connection.

## Running the Example

```bash
cd elixir
mix deps.get
mix run examples/basic_example.exs
```

## License

MIT - See [LICENSE](../LICENSE) for details.
