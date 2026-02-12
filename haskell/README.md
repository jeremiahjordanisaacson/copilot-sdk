# Copilot Supercharged Haskell SDK

A Haskell SDK for interacting with the GitHub Copilot CLI server via JSON-RPC 2.0 over stdio.

## Overview

This SDK enables Haskell applications to communicate with the Copilot CLI server, create and manage conversation sessions, register custom tools, handle permissions and user input, and subscribe to session events.

The SDK follows the same patterns as the official Node.js, Python, Go, and .NET SDKs.

## Architecture

```
┌────────────────────┐         stdio (JSON-RPC 2.0)         ┌─────────────────┐
│   Haskell Client   │ ◄────── Content-Length framing ──────► │  Copilot CLI    │
│                    │                                       │  (--headless    │
│  CopilotClient     │  Requests:  session.create/send/etc   │   --stdio)      │
│  CopilotSession    │  Server→:  tool.call, permission.*   │                 │
│  JsonRpcClient     │  Notifs:   session.event             │                 │
└────────────────────┘                                       └─────────────────┘
```

### Modules

| Module | Description |
|--------|-------------|
| `Copilot.Client` | Main entry point. Spawns CLI process, manages sessions. |
| `Copilot.Session` | Session operations: send, sendAndWait, events, lifecycle. |
| `Copilot.JsonRpc` | JSON-RPC 2.0 client with Content-Length header framing. |
| `Copilot.Types` | All data types with Aeson JSON instances. |
| `Copilot.DefineTool` | Helper functions for defining tools. |
| `Copilot.SdkProtocolVersion` | Protocol version constant (must match server). |

## Installation

Add to your `cabal.project` or use as a local dependency:

```cabal
build-depends: copilot-sdk-supercharged
```

### Dependencies

- `aeson` - JSON serialization/deserialization
- `text` - Text type
- `bytestring` - Binary I/O for Content-Length framing
- `process` - Spawning the CLI subprocess
- `async` - Concurrent operations
- `stm` - Thread-safe state (TVar, TMVar)
- `uuid` - Generating JSON-RPC request IDs
- `containers` - Map for pending requests and handlers

## Quick Start

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Copilot.Client
import Copilot.Session
import Copilot.Types

main :: IO ()
main = do
  -- Create and start client
  client <- newCopilotClient defaultClientOptions
  startClient client

  -- Create a session
  session <- createSession client defaultSessionConfig

  -- Subscribe to events
  unsubscribe <- onSessionEvent session $ \evt ->
    case seType evt of
      "assistant.message" -> putStrLn $ "Assistant: " ++ show (seData evt)
      _ -> pure ()

  -- Send a message and wait for response
  response <- sendAndWait session
    (MessageOptions "What is 2+2?" Nothing Nothing)
    Nothing  -- default 60s timeout

  -- Clean up
  unsubscribe
  destroySession session
  _ <- stopClient client
  pure ()
```

## Defining Custom Tools

Tools allow the Copilot assistant to call functions you define:

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

import Data.Aeson (FromJSON, (.=), object)
import GHC.Generics (Generic)
import Copilot.DefineTool
import Copilot.Types

data SearchArgs = SearchArgs { query :: Text }
  deriving (Show, Generic)

instance FromJSON SearchArgs

searchTool :: Tool
searchTool = defineSimpleTool
  "search"
  (Just "Search the web")
  (Just $ object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "query" .= object [ "type" .= ("string" :: Text) ] ]
    , "required" .= (["query"] :: [Text])
    ])
  (\(SearchArgs q) _inv -> pure $ "Results for: " <> q)

-- Use in session config:
-- createSession client defaultSessionConfig { scTools = [searchTool] }
```

For full control over the result type, use `defineTool` instead of `defineSimpleTool`:

```haskell
myTool :: Tool
myTool = defineTool "my_tool" (Just "Description") Nothing $ \args inv -> do
  -- args :: Value (raw JSON)
  -- inv :: ToolInvocation (session context)
  pure $ ToolResultStruct $ ToolResultObject
    { troTextResultForLlm    = "Tool executed successfully"
    , troBinaryResultsForLlm = Nothing
    , troResultType          = Success
    , troError               = Nothing
    , troSessionLog          = Nothing
    , troToolTelemetry       = Nothing
    }
```

## Permission Handling

Register a handler to control tool permissions:

```haskell
session <- createSession client defaultSessionConfig
  { scOnPermissionRequest = Just $ \req sessionId -> do
      putStrLn $ "Permission requested: " ++ show (prKind req)
      pure $ PermissionRequestResult "approved" Nothing
  }
```

## User Input Handling

Allow the assistant to ask the user questions:

```haskell
session <- createSession client defaultSessionConfig
  { scOnUserInputRequest = Just $ \req sessionId -> do
      putStrLn $ "Question: " ++ show (uirQuestion req)
      pure $ UserInputResponse "yes" True
  }
```

## Hooks

Intercept session lifecycle events:

```haskell
session <- createSession client defaultSessionConfig
  { scHooks = Just defaultSessionHooks
      { shOnPreToolUse = Just $ \input inv -> do
          putStrLn $ "About to use tool: " ++ show (ptuToolName input)
          pure $ Just PreToolUseHookOutput
            { ptuoPermissionDecision       = Just "allow"
            , ptuoPermissionDecisionReason = Nothing
            , ptuoModifiedArgs             = Nothing
            , ptuoAdditionalContext        = Nothing
            , ptuoSuppressOutput           = Nothing
            }
      }
  }
```

## Event Handling

Subscribe to specific event types:

```haskell
unsubscribe <- onSessionEvent session $ \evt ->
  case seType evt of
    "session.start"           -> putStrLn "Session started"
    "assistant.message"       -> putStrLn "Got assistant message"
    "assistant.message_delta" -> putStrLn "Streaming delta..."
    "tool.execution_start"    -> putStrLn "Tool executing..."
    "tool.execution_complete" -> putStrLn "Tool done"
    "session.idle"            -> putStrLn "Session idle"
    "session.error"           -> putStrLn "Session error!"
    _                         -> pure ()
```

## Client Options

```haskell
let opts = defaultClientOptions
      { ccoCliPath    = Just "/path/to/copilot"
      , ccoLogLevel   = "debug"
      , ccoAutoStart  = True
      , ccoGithubToken = Just "ghp_xxx"
      }
client <- newCopilotClient opts
```

## JSON-RPC Protocol

The SDK communicates using JSON-RPC 2.0 with Content-Length header framing
(the same framing used by the Language Server Protocol):

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":"uuid","method":"session.create","params":{...}}
```

### Client-to-Server Methods

| Method | Description |
|--------|-------------|
| `ping` | Health check, returns protocol version |
| `status.get` | Get CLI version and protocol info |
| `auth.getStatus` | Get authentication status |
| `models.list` | List available models |
| `session.create` | Create a new session |
| `session.resume` | Resume an existing session |
| `session.send` | Send a message to a session |
| `session.destroy` | Destroy a session |
| `session.delete` | Permanently delete a session |
| `session.list` | List all sessions |
| `session.getMessages` | Get session history |
| `session.abort` | Abort current processing |
| `session.getLastId` | Get the last session ID |

### Server-to-Client Requests

| Method | Description |
|--------|-------------|
| `tool.call` | Execute a registered tool |
| `permission.request` | Request permission for an operation |
| `userInput.request` | Request user input |
| `hooks.invoke` | Invoke a session hook |

### Server-to-Client Notifications

| Method | Description |
|--------|-------------|
| `session.event` | Session event (message, idle, error, etc.) |
| `session.lifecycle` | Session lifecycle event (created, deleted, etc.) |

## Building

```bash
cabal build
```

## Running the Example

```bash
cabal run copilot-basic-example
```

## Protocol Version

The SDK protocol version is `2`. This must match the server version.
The client verifies this on startup via a ping request.

## Thread Safety

- The JSON-RPC client uses STM (`TVar`, `TMVar`) for thread-safe pending request tracking
- A write lock (`TMVar`) ensures atomic message writing to the CLI stdin
- Session event handlers are called synchronously; handler exceptions are caught and ignored
- The async reader thread runs continuously in the background, dispatching messages
