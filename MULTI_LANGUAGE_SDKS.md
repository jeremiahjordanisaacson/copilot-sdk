# Multi-Language SDK Expansion

## Overview

This document records the expansion of the GitHub Copilot SDK from 4 officially supported languages to 20 languages, adding full SDK implementations for 16 additional programming languages in a single session.

## Original SDKs (4 languages)

The repository originally shipped with SDKs for:

| Language | Directory | Package |
|----------|-----------|---------|
| Node.js / TypeScript | `nodejs/` | `@github/copilot-sdk` |
| Python | `python/` | `github-copilot-sdk` |
| Go | `go/` | `github.com/github/copilot-sdk/go` |
| .NET / C# | `dotnet/` | `GitHub.Copilot.SDK` |

## Added SDKs (16 languages)

All 16 SDKs were built to match the existing SDK architecture exactly, implementing the same JSON-RPC 2.0 protocol, the same CLI spawn pattern, and the same core API surface.

| # | Language | Directory | Files | Lines | Key Technologies | Commit |
|---|----------|-----------|-------|-------|------------------|--------|
| 1 | **Java** | `java/` | 13 | 2,092 | Jackson, Maven, Java 17+ | `9ecf6bd` |
| 2 | **Rust** | `rust/` | 10 | 3,837 | tokio, serde, async/await | `f389cf4` |
| 3 | **Ruby** | `ruby/` | 11 | 2,567 | Ruby stdlib only, threads | `02e1a09` |
| 4 | **PHP** | `php/` | 9 | 4,505 | PHP 8.1+, proc_open, PSR-4 | `a2e8f89` |
| 5 | **Kotlin** | `kotlin/` | 10 | 2,798 | Coroutines, kotlinx.serialization, Gradle | `601c389` |
| 6 | **Dart** | `dart/` | 10 | 3,728 | Streams, Completers, pub | `9d1fe2d` |
| 7 | **Lua** | `lua/` | 9 | 2,778 | lua-cjson, metatables, LuaRocks | `c968037` |
| 8 | **Swift** | `swift/` | 9 | 3,431 | Actors, async/await, Codable, SPM | `6bdd8b9` |
| 9 | **C++** | `cpp/` | 12 | 3,500 | nlohmann/json, std::thread, CMake | `1ec6d87` |
| 10 | **C** | `c/` | 9 | 4,180 | cJSON, pthreads, cross-platform, CMake | `161b393` |
| 11 | **Scala** | `scala/` | 10 | 2,977 | Scala 3, circe, Futures, sbt | `c778cad` |
| 12 | **R** | `r/` | 10 | 2,809 | R6, processx, jsonlite, CRAN | `8b3cc5f` |
| 13 | **Perl** | `perl/` | 9 | 2,602 | Moo, IPC::Open3, threads, CPAN | `5f4f4d9` |
| 14 | **Elixir** | `elixir/` | 10 | 3,201 | GenServer, Port, Jason, Mix | `9ddad70` |
| 15 | **Shell/Bash** | `shell/` | 7 | 1,334 | coproc, jq, bash 4+ | `d5a36aa` |
| 16 | **Haskell** | `haskell/` | 9 | 3,275 | STM, async, aeson, Cabal | `6442c09` |

**Total: 162 new files, ~49,600 lines of code, 17 commits**

## SDK Architecture

Every SDK implements the same core architecture, adapted to each language's idioms:

```
Your Application
       |
   SDK Client (language-specific)
       | (JSON-RPC 2.0 over stdio or TCP)
   Copilot CLI Server
       |
   LLM Provider
```

### Core Components

Each SDK provides these components:

1. **JSON-RPC Client** - Content-Length header framing (`Content-Length: N\r\n\r\n{json}`) over stdio pipes or TCP sockets. Handles bidirectional communication: client-to-server requests and server-to-client requests/notifications.

2. **CopilotClient** - Main entry point that:
   - Spawns the CLI process with `--headless --no-auto-update --log-level <level> --stdio`
   - Manages connection lifecycle (start, stop, force stop, auto-restart)
   - Creates and resumes sessions
   - Handles server-to-client requests (tool.call, permission.request, userInput.request, hooks.invoke)
   - Routes session events and lifecycle events
   - Provides ping, status, auth status, model listing (with caching)
   - Supports TUI+server mode (foreground session management)
   - Supports GitHub token authentication and BYOK providers

3. **CopilotSession** - Represents a conversation:
   - `send()` - Fire-and-forget message sending
   - `sendAndWait()` - Send and block until `session.idle` event
   - Event subscriptions (wildcard and typed)
   - Tool handler registration and dispatch
   - Permission, user input, and hooks handler delegation
   - Message history retrieval
   - Abort and destroy lifecycle

4. **Types** - All protocol types: ConnectionState, SessionEvent, ToolResult, ToolInvocation, PermissionRequest/Result, UserInputRequest/Response, SessionHooks (all 6 hook types), ProviderConfig, MCPServerConfig, CustomAgentConfig, InfiniteSessionConfig, ModelInfo, SessionMetadata, SessionLifecycleEvent, MessageOptions, etc.

5. **SDK Protocol Version** - Constant (`2`) verified against the server via ping response on connect.

6. **DefineTool Helper** - Language-idiomatic helper for creating tool definitions with automatic result normalization and error handling.

7. **Example + README** - Working example demonstrating client creation, custom tools, event handling, and sendAndWait. Full README with installation, quick start, API reference.

### Protocol Details

- **Transport**: JSON-RPC 2.0 over stdio (default) or TCP
- **Framing**: LSP-style Content-Length headers
- **Client-to-Server Methods**: `ping`, `status.get`, `auth.getStatus`, `models.list`, `session.create`, `session.resume`, `session.send`, `session.getMessages`, `session.destroy`, `session.abort`, `session.list`, `session.delete`, `session.getForeground`, `session.setForeground`, `session.getLastId`
- **Server-to-Client Requests**: `tool.call`, `permission.request`, `userInput.request`, `hooks.invoke`
- **Server-to-Client Notifications**: `session.event` (30+ event types), `session.lifecycle`

## Build Process

The 16 SDKs were built using a parallelized approach:

1. **Java SDK** was built first as the reference implementation for the new languages
2. **15 background agents** were launched concurrently, each building one SDK
3. Each SDK was committed individually as it completed, enabling frequent shipping
4. All commits were pushed to the remote repository

### Language-Specific Design Decisions

| Language | Concurrency Model | JSON Library | Process Spawning |
|----------|------------------|--------------|-----------------|
| Java | `CompletableFuture`, `ConcurrentHashMap` | Jackson | `ProcessBuilder` |
| Rust | `tokio` async/await, `Arc<Mutex>` | serde_json | `tokio::process::Command` |
| Ruby | `Thread`, `Mutex`, `ConditionVariable` | stdlib `json` | `Open3.popen3` |
| PHP | Synchronous with `stream_select` | stdlib `json_encode` | `proc_open` |
| Swift | `actor`, `async/await` | Foundation `Codable` | `Process` + `Pipe` |
| Kotlin | `suspend` functions, `CompletableDeferred` | kotlinx.serialization | `ProcessBuilder` |
| C++ | `std::thread`, `std::condition_variable` | nlohmann/json | `fork`/`execvp` (POSIX), `CreateProcess` (Win) |
| C | `pthread`, `pthread_cond_wait` | cJSON | `fork`/`execvp` (POSIX), `CreateProcess` (Win) |
| Dart | `async/await`, `Stream`, `Completer` | `dart:convert` | `Process.start` |
| Scala | `Future`, `Promise` | circe | `ProcessBuilder` |
| R | Single-threaded polling | jsonlite | `processx::process` |
| Perl | `threads`, `Thread::Queue` | JSON::PP | `IPC::Open3` |
| Lua | Coroutines (single-threaded) | lua-cjson | `io.popen` |
| Shell/Bash | `coproc` (bash coprocess) | jq | `coproc` |
| Elixir | `GenServer`, `Port`, `Task` | Jason | `Port.open` |
| Haskell | `STM`, `async`, `MVar` | aeson | `System.Process` |

## Date

February 11, 2026

## Credits

Built with Claude Opus 4.6 (1M context) using parallel agent orchestration.
