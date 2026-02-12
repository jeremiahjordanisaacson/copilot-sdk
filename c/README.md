# GitHub Copilot Supercharged SDK for C

A C11 SDK for interacting with the GitHub Copilot CLI server via JSON-RPC 2.0 over stdio. This SDK follows the same architecture and patterns as the official Node.js, Python, Go, and .NET SDKs.

## Requirements

- **C11 compiler** (GCC, Clang, or MSVC)
- **CMake** 3.14 or later
- **pthreads** (POSIX threads; included on Linux/macOS, via pthreads-win32 or native on Windows with MSVC)
- **Copilot CLI** installed and on PATH (or specify `cli_path`)
- **GitHub authentication** (OAuth token, `gh` CLI auth, or `GITHUB_TOKEN` environment variable)

### Dependencies (automatically fetched)

- **[cJSON](https://github.com/DaveGamble/cJSON)** - Lightweight JSON parser for C (fetched via CMake FetchContent)

## Building

```bash
mkdir build && cd build
cmake ..
cmake --build .
```

To build without examples:

```bash
cmake -DCOPILOT_SDK_BUILD_EXAMPLES=OFF ..
```

## Quick Start

```c
#include "copilot/copilot.h"
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    /* Create and start client */
    copilot_client_options_t opts = copilot_client_options_default();
    copilot_client_t *client = copilot_client_create(&opts);
    copilot_client_start(client);

    /* Create a session */
    copilot_session_t *session = NULL;
    copilot_client_create_session(client, NULL, &session);

    /* Send a message and wait for the response */
    copilot_message_options_t msg = { .prompt = "What is 2 + 2?" };
    char *response = NULL;
    copilot_error_t err = copilot_session_send_and_wait(session, &msg, 60000, &response);

    if (err == COPILOT_OK && response) {
        printf("Assistant: %s\n", response);
        free(response);
    }

    /* Clean up */
    copilot_session_destroy(session);
    copilot_session_free(session);
    copilot_client_stop(client);
    copilot_client_free(client);
    return 0;
}
```

## Architecture

```
copilot_client_create()
    |
copilot_client_start()
    |-- Spawns CLI process with --headless --no-auto-update --log-level info --stdio
    |-- Creates JSON-RPC 2.0 connection over stdin/stdout pipes
    |-- Starts background reader thread for incoming messages
    |-- Verifies protocol version via ping
    |
copilot_client_create_session()
    |-- Sends session.create RPC request
    |-- Returns opaque session handle
    |
copilot_session_send() / copilot_session_send_and_wait()
    |-- Sends session.send RPC request
    |-- Events delivered via registered callbacks
    |-- send_and_wait blocks on pthread_cond_wait until session.idle
    |
copilot_session_destroy() + copilot_session_free()
copilot_client_stop() + copilot_client_free()
```

## API Reference

### Client

| Function | Description |
|----------|-------------|
| `copilot_client_options_default()` | Returns default client options |
| `copilot_client_create(opts)` | Creates a new client |
| `copilot_client_start(client)` | Starts CLI server and connects |
| `copilot_client_stop(client)` | Stops client and kills CLI process |
| `copilot_client_free(client)` | Frees client memory |
| `copilot_client_get_state(client)` | Returns connection state |
| `copilot_client_ping(client, msg, out)` | Pings server |
| `copilot_client_list_models(client, out)` | Lists available models |
| `copilot_client_list_sessions(client, out)` | Lists server sessions |
| `copilot_client_delete_session(client, id)` | Deletes a session |
| `copilot_client_create_session(client, cfg, out)` | Creates a session |
| `copilot_client_resume_session(client, id, cfg, out)` | Resumes a session |

### Session

| Function | Description |
|----------|-------------|
| `copilot_session_get_id(session)` | Returns session ID |
| `copilot_session_get_workspace_path(session)` | Returns workspace path |
| `copilot_session_send(session, opts, out_mid)` | Sends a message (async) |
| `copilot_session_send_and_wait(session, opts, timeout, out)` | Sends and waits for idle |
| `copilot_session_on(session, handler, data)` | Registers event handler |
| `copilot_session_on_type(session, type, handler, data)` | Registers typed event handler |
| `copilot_session_off(session, handler_id)` | Unregisters event handler |
| `copilot_session_destroy(session)` | Destroys session (server-side) |
| `copilot_session_free(session)` | Frees session memory |
| `copilot_session_abort(session)` | Aborts current processing |

### Tools

Define tools that the Copilot assistant can invoke:

```c
static copilot_error_t my_tool_handler(
    const copilot_tool_invocation_t *invocation,
    void *user_data,
    copilot_tool_result_t *out_result)
{
    /* Parse invocation->arguments_json, do work, fill out_result */
    out_result->text_result_for_llm = "Result text";
    out_result->result_type = COPILOT_TOOL_RESULT_SUCCESS;
    return COPILOT_OK;
}

copilot_tool_t tools[] = {
    {
        .name = "my_tool",
        .description = "Does something useful",
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
        .handler = my_tool_handler,
        .user_data = NULL,
    },
};

copilot_session_config_t config = copilot_session_config_default();
config.tools = tools;
config.tools_count = 1;
```

### Permission Handling

```c
static copilot_error_t on_permission(
    const copilot_permission_request_t *request,
    const char *session_id,
    void *user_data,
    copilot_permission_result_t *out_result)
{
    /* Decide based on request->kind: "shell", "write", "read", etc. */
    out_result->kind = COPILOT_PERMISSION_APPROVED;
    return COPILOT_OK;
}

config.on_permission_request = on_permission;
```

### Event Handling

```c
static void on_event(const copilot_session_event_t *event, void *user_data)
{
    if (strcmp(event->type, "assistant.message") == 0) {
        printf("Assistant: %s\n", event->content);
    }
}

int handler_id = copilot_session_on(session, on_event, NULL);
/* ... */
copilot_session_off(session, handler_id);
```

### Streaming

Enable streaming to receive incremental content deltas:

```c
copilot_session_config_t config = copilot_session_config_default();
config.streaming = true;

/* In your event handler: */
if (strcmp(event->type, "assistant.message_delta") == 0) {
    printf("%s", event->delta_content);  /* Print incrementally */
    fflush(stdout);
}
```

### Custom Provider (BYOK)

```c
copilot_provider_config_t provider = {
    .type = "openai",
    .base_url = "http://localhost:11434/v1",
    .api_key = NULL,  /* Ollama doesn't need a key */
};

copilot_session_config_t config = copilot_session_config_default();
config.model = "llama3";
config.provider = &provider;
```

## Protocol

The SDK communicates with the Copilot CLI server using:

- **Transport**: stdin/stdout pipes (stdio mode)
- **Protocol**: JSON-RPC 2.0
- **Framing**: Content-Length headers (same as LSP)
- **Threading**: Background pthread for reading incoming messages

### Message Flow

```
SDK                             CLI Server
 |                                   |
 |--- session.create --------------->|
 |<-- {sessionId} ------------------|
 |                                   |
 |--- session.send ----------------->|
 |<-- {messageId} ------------------|
 |                                   |
 |<-- session.event (tool.executing)|
 |<-- tool.call --------------------|
 |--- {result} -------------------->|
 |<-- session.event (tool.executed) |
 |<-- session.event (assistant.message)|
 |<-- session.event (session.idle)  |
 |                                   |
 |--- session.destroy -------------->|
```

## Memory Management

The SDK uses a create/destroy/free pattern:

- `*_create()` allocates and initializes
- `*_destroy()` releases server-side resources
- `*_free()` releases client-side memory
- Always call `destroy` before `free`
- Strings returned via output parameters must be freed with `free()`
- List results (models, sessions) must be freed with their respective `*_free()` functions

## Thread Safety

- The JSON-RPC client uses a background reader thread (pthread)
- Event handlers are called from the reader thread context
- `send_and_wait` uses pthread_cond_wait for blocking synchronization
- The session and client structures use mutexes for handler registration
- Tool handlers, permission handlers, and hook handlers are called synchronously from the reader thread; avoid blocking for extended periods

## Error Handling

All functions that can fail return `copilot_error_t`. Use `copilot_error_string()` for human-readable descriptions:

```c
copilot_error_t err = copilot_client_start(client);
if (err != COPILOT_OK) {
    fprintf(stderr, "Error: %s\n", copilot_error_string(err));
}
```

## License

See the [LICENSE](../LICENSE) file in the repository root.
