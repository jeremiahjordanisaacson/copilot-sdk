# Copilot Supercharged CLI SDK for Shell/Bash

A Bash library for communicating with the GitHub Copilot CLI server via JSON-RPC 2.0 over stdio. This SDK follows the same patterns as the existing Node.js, Python, Go, and .NET SDKs.

## Requirements

- **bash 4.0+** (for `coproc`, associative arrays, and other modern features)
- **jq** (for JSON parsing and construction)
- **copilot CLI** in your `PATH` (or provide the path explicitly)

### Checking Requirements

```bash
# Check bash version
bash --version

# Check jq is installed
jq --version

# Check copilot CLI is available
copilot --version
```

## Quick Start

```bash
#!/usr/bin/env bash
set -euo pipefail

# Source the SDK
source /path/to/copilot-sdk-supercharged/shell/lib/copilot_sdk.sh

# Start the client (spawns copilot CLI process)
copilot_client_start

# Create a session
copilot_client_create_session

# Send a message and wait for the response
copilot_session_send_and_wait "What is 2+2?"
echo "Response: $COPILOT_SESSION_LAST_RESPONSE"

# Clean up
copilot_session_destroy
copilot_client_stop
```

## Architecture

The SDK is composed of four modules, each sourced by the main `copilot_sdk.sh` entry point:

```
shell/
  lib/
    copilot_sdk.sh           # Main entry point (sources all modules)
    sdk_protocol_version.sh  # Protocol version constant
    json_rpc.sh              # JSON-RPC 2.0 transport layer
    client.sh                # Client lifecycle and session management
    session.sh               # Session message sending and events
  examples/
    basic_example.sh         # Full working example
```

### Module Overview

| Module | Purpose |
|--------|---------|
| `sdk_protocol_version.sh` | Defines `COPILOT_SDK_PROTOCOL_VERSION=2` matching the server expectation |
| `json_rpc.sh` | Low-level JSON-RPC 2.0 over stdio with Content-Length framing using `coproc` |
| `client.sh` | Client lifecycle: start/stop, ping, create/resume/delete sessions, list models |
| `session.sh` | Session operations: send, send_and_wait, get_messages, abort, destroy |

## API Reference

### Client Functions

#### `copilot_client_start [cli_path] [log_level]`

Start the Copilot CLI client. Spawns the CLI server process and verifies the protocol version.

- `cli_path` - Path to the copilot CLI binary (default: `"copilot"`)
- `log_level` - Log level (default: `"info"`)

```bash
copilot_client_start                        # Use default copilot from PATH
copilot_client_start "/usr/local/bin/copilot" "debug"  # Custom path and log level
```

#### `copilot_client_stop`

Stop the CLI server and clean up all resources.

```bash
copilot_client_stop
```

#### `copilot_client_ping [message]`

Send a ping to verify server connectivity. Sets `COPILOT_JSONRPC_LAST_RESPONSE`.

```bash
copilot_client_ping "health check"
protocol_version=$(copilot_jsonrpc_get_result_field '.protocolVersion')
```

#### `copilot_client_create_session [model] [system_message]`

Create a new conversation session. Sets `COPILOT_SESSION_ID`.

```bash
copilot_client_create_session                    # Default model
copilot_client_create_session "gpt-4"            # Specific model
copilot_client_create_session "" "You are helpful"  # With system message
```

#### `copilot_client_resume_session <session_id> [model]`

Resume an existing session. Sets `COPILOT_SESSION_ID`.

```bash
copilot_client_resume_session "abc-123"
```

#### `copilot_client_delete_session <session_id>`

Delete a session permanently.

```bash
copilot_client_delete_session "abc-123"
```

#### `copilot_client_list_models`

List available models. Results in `COPILOT_JSONRPC_LAST_RESPONSE`.

```bash
copilot_client_list_models
copilot_jsonrpc_get_result_field '.models' | jq -r '.[].id'
```

#### `copilot_client_list_sessions`

List all sessions. Results in `COPILOT_JSONRPC_LAST_RESPONSE`.

```bash
copilot_client_list_sessions
copilot_jsonrpc_get_result_field '.sessions' | jq -r '.[].sessionId'
```

### Session Functions

All session functions default to using `COPILOT_SESSION_ID` but accept an optional session ID parameter.

#### `copilot_session_send <prompt> [session_id]`

Send a message (fire-and-forget). Returns immediately.

```bash
copilot_session_send "Hello, world!"
message_id=$(copilot_jsonrpc_get_result_field '.messageId')
```

#### `copilot_session_send_and_wait <prompt> [session_id] [timeout] [poll_interval]`

Send a message and block until the session becomes idle. Sets `COPILOT_SESSION_LAST_RESPONSE` to the assistant's reply.

```bash
copilot_session_send_and_wait "What is 2+2?"
echo "$COPILOT_SESSION_LAST_RESPONSE"

# With custom timeout (120 seconds)
copilot_session_send_and_wait "Write a long story" "" 120
```

#### `copilot_session_get_messages [session_id]`

Retrieve all events from session history. Sets `COPILOT_SESSION_MESSAGES` (JSON array).

```bash
copilot_session_get_messages
echo "$COPILOT_SESSION_MESSAGES" | jq '.[] | select(.type == "assistant.message") | .data.content'
```

#### `copilot_session_abort [session_id]`

Abort the currently processing message.

```bash
copilot_session_abort
```

#### `copilot_session_destroy [session_id]`

Destroy the session and release resources.

```bash
copilot_session_destroy
```

### JSON-RPC Functions (Low-Level)

These are used internally but available for advanced use cases.

#### `copilot_jsonrpc_start <cli_path> [extra_args...]`

Start the CLI process as a coproc.

#### `copilot_jsonrpc_stop`

Stop the CLI process and clean up.

#### `copilot_jsonrpc_request <method> [params_json] [timeout]`

Send a JSON-RPC request and wait for the response.

#### `copilot_jsonrpc_send_message <json_body>`

Send a raw Content-Length framed message.

#### `copilot_jsonrpc_read_message`

Read a Content-Length framed message. Sets `COPILOT_JSONRPC_LAST_RESPONSE`.

#### `copilot_jsonrpc_get_result`

Extract the `.result` from the last response.

#### `copilot_jsonrpc_get_result_field <jq_path>`

Extract a specific field from `.result`.

#### `copilot_jsonrpc_is_connected`

Check if the CLI process is still running.

## Global Variables

| Variable | Description |
|----------|-------------|
| `COPILOT_SDK_PROTOCOL_VERSION` | Protocol version (currently 2) |
| `COPILOT_SDK_NAME` | SDK name (`copilot-sdk-shell`) |
| `COPILOT_SDK_VERSION` | SDK version |
| `COPILOT_CLIENT_STATE` | Connection state: `disconnected`, `connecting`, `connected`, `error` |
| `COPILOT_SESSION_ID` | Active session ID (set by create/resume) |
| `COPILOT_SESSION_LAST_RESPONSE` | Last assistant response text from `send_and_wait` |
| `COPILOT_SESSION_MESSAGES` | JSON array from `get_messages` |
| `COPILOT_JSONRPC_LAST_RESPONSE` | Raw JSON of last JSON-RPC response |
| `COPILOT_JSONRPC_LAST_ERROR` | Raw JSON of last JSON-RPC error |
| `COPILOT_JSONRPC_PID` | PID of the CLI coproc process |

## Error Handling

All functions return 0 on success and 1 on failure, with error messages written to stderr. Use standard bash error handling patterns:

```bash
# Check return codes
if ! copilot_client_start; then
    echo "Failed to start client" >&2
    exit 1
fi

# Or use set -e (enabled by copilot_sdk.sh)
set -e
copilot_client_start
copilot_client_create_session
```

## Protocol Details

The SDK communicates with the Copilot CLI using JSON-RPC 2.0 over stdio with Content-Length header framing, identical to the LSP (Language Server Protocol) transport:

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
```

The CLI process is launched with:
```
copilot --headless --no-auto-update --log-level info --stdio
```

## Examples

See `examples/basic_example.sh` for a complete working example that demonstrates all major SDK features.

## License

Copyright (c) Microsoft Corporation. All rights reserved.
