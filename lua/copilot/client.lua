--- CopilotClient: manages the connection to the Copilot CLI server.
--
-- Spawns the CLI process, communicates over JSON-RPC 2.0 via stdio,
-- and provides session lifecycle management.
--
-- Usage:
--   local CopilotClient = require("copilot.client")
--   local client = CopilotClient.new()
--   client:start()
--   local session = client:create_session({ model = "gpt-4" })
--   -- ...
--   client:stop()

local cjson               = require("cjson")
local JsonRpcClient       = require("copilot.json_rpc_client")
local CopilotSession      = require("copilot.session")
local types               = require("copilot.types")
local sdk_protocol_version = require("copilot.sdk_protocol_version")

-- ---------------------------------------------------------------------------
-- CopilotClient class
-- ---------------------------------------------------------------------------

local CopilotClient = {}
CopilotClient.__index = CopilotClient

--- Create a new CopilotClient.
-- @param options table|nil  ClientOptions (see types.ClientOptions)
-- @return CopilotClient
function CopilotClient.new(options)
    options = options or {}
    local self = setmetatable({}, CopilotClient)

    -- Resolve options with defaults
    self._cli_path       = options.cliPath or os.getenv("COPILOT_CLI_PATH") or "copilot"
    self._cwd            = options.cwd
    self._log_level      = options.logLevel or "info"
    self._env            = options.env
    self._github_token   = options.githubToken
    self._use_logged_in  = options.useLoggedInUser
    self._auto_start     = (options.autoStart ~= false)
    self._auto_restart   = (options.autoRestart ~= false)

    -- State
    self._state          = types.ConnectionState.DISCONNECTED
    self._process        = nil    -- popen handle
    self._rpc_client     = nil    -- JsonRpcClient instance
    self._sessions       = {}     -- sessionId -> CopilotSession
    self._models_cache   = nil    -- cached array of ModelInfo
    self._stdin_handle   = nil
    self._stdout_handle  = nil
    self._read_thread    = nil    -- coroutine for the read loop

    return self
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Start the CLI server process and connect.
-- @return boolean success
-- @return string|nil error message
function CopilotClient:start()
    if self._state == types.ConnectionState.CONNECTED then
        return true, nil
    end

    self._state = types.ConnectionState.CONNECTING

    -- Build command line arguments
    local args = {
        self._cli_path,
        "--headless",
        "--no-auto-update",
        "--log-level", self._log_level,
        "--stdio",
    }

    -- Authentication flags
    if self._github_token and self._github_token ~= "" then
        table.insert(args, "--auth-token-env")
        table.insert(args, "COPILOT_SDK_AUTH_TOKEN")
    end

    local use_logged_in = true
    if self._use_logged_in ~= nil then
        use_logged_in = self._use_logged_in
    elseif self._github_token and self._github_token ~= "" then
        use_logged_in = false
    end
    if not use_logged_in then
        table.insert(args, "--no-auto-login")
    end

    -- Build command string
    local cmd = table.concat(args, " ")

    -- Set environment variable for auth token if needed
    if self._github_token and self._github_token ~= "" then
        -- On POSIX systems, we can prepend env vars
        if package.config:sub(1, 1) == "/" then
            cmd = string.format("COPILOT_SDK_AUTH_TOKEN=%s %s",
                self._github_token, cmd)
        else
            -- On Windows, use set command
            cmd = string.format("set COPILOT_SDK_AUTH_TOKEN=%s && %s",
                self._github_token, cmd)
        end
    end

    -- Open the process with bidirectional stdio via io.popen
    -- Lua 5.1/5.2 io.popen only gives one direction. We need a workaround.
    -- Strategy: use a pair of popen calls or the luaposix / LuaSocket approach.
    -- For maximum portability, we use os.tmpname + shell redirect approach:
    --   - Create a named pipe (FIFO) for writing to the process
    --   - popen gives us the reading end
    -- On Windows, we rely on a helper script or _popen2 if available.
    --
    -- Simplest cross-platform approach: use io.popen in read mode and write
    -- to a temporary fifo. But for the initial release, we use the Lua 5.3+
    -- io.popen("cmd", "w") for stdin and a separate mechanism for stdout.
    --
    -- PRACTICAL APPROACH: Use popen2-style function via os-level pipes.
    -- We provide a portable implementation using temporary files and coroutines.

    local ok, stdin_w, stdout_r, err = self:_spawn_process(cmd)
    if not ok then
        self._state = types.ConnectionState.ERROR
        return false, "Failed to start CLI server: " .. tostring(err)
    end

    self._stdin_handle  = stdin_w
    self._stdout_handle = stdout_r

    -- Create JSON-RPC client
    self._rpc_client = JsonRpcClient.new(stdin_w, stdout_r)

    -- Setup notification / request handlers
    self:_setup_handlers()

    -- Start the read loop in a coroutine
    self._read_thread = coroutine.create(function()
        self._rpc_client:run()
    end)

    -- Kick off the read loop coroutine (it will yield on I/O)
    -- For synchronous mode, the read loop runs inline inside request()

    -- Verify protocol version
    local ping_ok, ping_err = self:_verify_protocol_version()
    if not ping_ok then
        self._state = types.ConnectionState.ERROR
        return false, ping_err
    end

    self._state = types.ConnectionState.CONNECTED
    return true, nil
end

--- Stop the CLI server and clean up all sessions.
-- @return boolean success
-- @return string|nil error message
function CopilotClient:stop()
    local errors = {}

    -- Destroy all active sessions
    for session_id, session in pairs(self._sessions) do
        local ok, err = session:destroy()
        if not ok then
            table.insert(errors, string.format(
                "failed to destroy session %s: %s", session_id, tostring(err)
            ))
        end
    end
    self._sessions = {}

    -- Stop JSON-RPC client
    if self._rpc_client then
        self._rpc_client:stop()
        self._rpc_client = nil
    end

    -- Close process handles
    if self._stdin_handle then
        pcall(function() self._stdin_handle:close() end)
        self._stdin_handle = nil
    end
    if self._stdout_handle then
        pcall(function() self._stdout_handle:close() end)
        self._stdout_handle = nil
    end
    if self._process then
        pcall(function() self._process:close() end)
        self._process = nil
    end

    -- Clear models cache
    self._models_cache = nil

    self._state = types.ConnectionState.DISCONNECTED

    if #errors > 0 then
        return false, table.concat(errors, "; ")
    end
    return true, nil
end

--- Get the current connection state.
-- @return string  One of the ConnectionState values
function CopilotClient:state()
    return self._state
end

--- Ensure the client is connected, auto-starting if configured.
-- @return boolean success
-- @return string|nil error
function CopilotClient:_ensure_connected()
    if self._rpc_client then
        return true, nil
    end
    if self._auto_start then
        return self:start()
    end
    return false, "Client not connected. Call start() first."
end

--- Ping the server.
-- @param message string|nil  Optional message to echo
-- @return table|nil PingResponse
-- @return string|nil error
function CopilotClient:ping(message)
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    local result, req_err = self._rpc_client:request("ping", {
        message = message or "",
    })
    if req_err then
        return nil, req_err
    end
    return result, nil
end

--- Get server status.
-- @return table|nil GetStatusResponse
-- @return string|nil error
function CopilotClient:get_status()
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    return self._rpc_client:request("status.get", {})
end

--- Get authentication status.
-- @return table|nil GetAuthStatusResponse
-- @return string|nil error
function CopilotClient:get_auth_status()
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    return self._rpc_client:request("auth.getStatus", {})
end

--- List available models (cached after first call).
-- @return table|nil  Array of ModelInfo
-- @return string|nil error
function CopilotClient:list_models()
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    if self._models_cache then
        return self._models_cache, nil
    end

    local result, req_err = self._rpc_client:request("models.list", {})
    if req_err then
        return nil, req_err
    end

    if result and result.models then
        self._models_cache = result.models
        return result.models, nil
    end
    return {}, nil
end

--- Create a new session.
-- @param config table|nil  SessionConfig (see types.SessionConfig)
-- @return CopilotSession|nil
-- @return string|nil error
function CopilotClient:create_session(config)
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    config = config or {}
    local req = self:_build_create_session_request(config)

    local result, req_err = self._rpc_client:request("session.create", req)
    if req_err then
        return nil, "failed to create session: " .. tostring(req_err)
    end

    if not result or not result.sessionId then
        return nil, "invalid create session response"
    end

    local session = CopilotSession.new(
        result.sessionId,
        self._rpc_client,
        result.workspacePath
    )

    -- Register tools, permission handler, user input handler, hooks
    session:_register_tools(config.tools)
    if config.onPermissionRequest then
        session:_register_permission_handler(config.onPermissionRequest)
    end
    if config.onUserInputRequest then
        session:_register_user_input_handler(config.onUserInputRequest)
    end
    if config.hooks then
        session:_register_hooks(config.hooks)
    end

    self._sessions[result.sessionId] = session
    return session, nil
end

--- Resume an existing session.
-- @param session_id string  The session ID to resume
-- @param config table|nil   ResumeSessionConfig
-- @return CopilotSession|nil
-- @return string|nil error
function CopilotClient:resume_session(session_id, config)
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    config = config or {}
    local req = self:_build_resume_session_request(session_id, config)

    local result, req_err = self._rpc_client:request("session.resume", req)
    if req_err then
        return nil, "failed to resume session: " .. tostring(req_err)
    end

    if not result or not result.sessionId then
        return nil, "invalid resume session response"
    end

    local session = CopilotSession.new(
        result.sessionId,
        self._rpc_client,
        result.workspacePath
    )

    session:_register_tools(config.tools)
    if config.onPermissionRequest then
        session:_register_permission_handler(config.onPermissionRequest)
    end
    if config.onUserInputRequest then
        session:_register_user_input_handler(config.onUserInputRequest)
    end
    if config.hooks then
        session:_register_hooks(config.hooks)
    end

    self._sessions[result.sessionId] = session
    return session, nil
end

--- List all sessions.
-- @return table|nil  Array of SessionMetadata
-- @return string|nil error
function CopilotClient:list_sessions()
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    local result, req_err = self._rpc_client:request("session.list", {})
    if req_err then
        return nil, req_err
    end

    if result and result.sessions then
        return result.sessions, nil
    end
    return {}, nil
end

--- Delete a session permanently.
-- @param session_id string
-- @return boolean success
-- @return string|nil error
function CopilotClient:delete_session(session_id)
    local ok, err = self:_ensure_connected()
    if not ok then return false, err end

    local result, req_err = self._rpc_client:request("session.delete", {
        sessionId = session_id,
    })
    if req_err then
        return false, req_err
    end

    if result and result.success then
        self._sessions[session_id] = nil
        return true, nil
    end

    local error_msg = "unknown error"
    if result and result.error then
        error_msg = result.error
    end
    return false, string.format("failed to delete session %s: %s", session_id, error_msg)
end

--- Get the foreground session ID (TUI+server mode only).
-- @return string|nil sessionId
-- @return string|nil error
function CopilotClient:get_foreground_session_id()
    local ok, err = self:_ensure_connected()
    if not ok then return nil, err end

    local result, req_err = self._rpc_client:request("session.getForeground", {})
    if req_err then
        return nil, req_err
    end
    return result and result.sessionId, nil
end

--- Set the foreground session (TUI+server mode only).
-- @param session_id string
-- @return boolean success
-- @return string|nil error
function CopilotClient:set_foreground_session_id(session_id)
    local ok, err = self:_ensure_connected()
    if not ok then return false, err end

    local result, req_err = self._rpc_client:request("session.setForeground", {
        sessionId = session_id,
    })
    if req_err then
        return false, req_err
    end
    if result and result.success then
        return true, nil
    end
    return false, result and result.error or "unknown error"
end

-- ---------------------------------------------------------------------------
-- Internal: Process spawning
-- ---------------------------------------------------------------------------

--- Spawn the CLI process with bidirectional stdio.
-- Returns write handle (to process stdin) and read handle (from process stdout).
--
-- This uses a cross-platform approach:
--   - On POSIX: uses popen with a FIFO for the write direction
--   - On Windows: uses a temp file relay approach
--
-- @param cmd string  The command to execute
-- @return boolean success
-- @return file|nil  write handle (to process stdin)
-- @return file|nil  read handle (from process stdout)
-- @return string|nil error
function CopilotClient:_spawn_process(cmd)
    local is_windows = (package.config:sub(1, 1) == "\\")

    if is_windows then
        return self:_spawn_process_windows(cmd)
    else
        return self:_spawn_process_posix(cmd)
    end
end

--- POSIX process spawn using a named pipe (FIFO).
function CopilotClient:_spawn_process_posix(cmd)
    -- Create a FIFO for writing to the process's stdin
    local fifo_path = os.tmpname() .. "_copilot_fifo"
    local mkfifo_ok = os.execute("mkfifo " .. fifo_path .. " 2>/dev/null")
    if not mkfifo_ok then
        -- Fallback: use /tmp path
        fifo_path = "/tmp/copilot_sdk_fifo_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000))
        os.execute("mkfifo " .. fifo_path)
    end

    -- Launch the process: stdin reads from fifo, stdout is captured by popen
    local full_cmd = string.format("%s < %s", cmd, fifo_path)
    local stdout_handle = io.popen(full_cmd, "r")
    if not stdout_handle then
        os.remove(fifo_path)
        return false, nil, nil, "failed to popen CLI process"
    end

    -- Open the FIFO for writing (this will block until the reader is connected,
    -- which happens when the process starts reading from stdin)
    local stdin_handle = io.open(fifo_path, "w")
    if not stdin_handle then
        stdout_handle:close()
        os.remove(fifo_path)
        return false, nil, nil, "failed to open FIFO for writing"
    end

    self._process = stdout_handle
    self._fifo_path = fifo_path

    return true, stdin_handle, stdout_handle, nil
end

--- Windows process spawn using a temp file relay.
-- On Windows, we use io.popen with read mode and write to a temp file
-- that is piped to the process stdin.
function CopilotClient:_spawn_process_windows(cmd)
    -- On Windows, use a simpler approach with named pipes via cmd.exe
    -- We create a background process and communicate via temp files.
    -- For a production SDK, one would use luaposix or a C extension.
    --
    -- Practical approach: use io.popen in read mode. For writes, we
    -- create a wrapper that sends data via a temp file and pipe.

    -- Create temp file for stdin relay
    local stdin_pipe_path = os.tmpname()

    -- The command reads from the pipe file
    -- We use 'type' on Windows to feed the pipe
    local full_cmd = string.format('cmd /c "type %s | %s"', stdin_pipe_path, cmd)

    -- Open stdin pipe for writing
    local stdin_handle = io.open(stdin_pipe_path, "w")
    if not stdin_handle then
        return false, nil, nil, "failed to create stdin temp file"
    end

    local stdout_handle = io.popen(full_cmd, "r")
    if not stdout_handle then
        stdin_handle:close()
        os.remove(stdin_pipe_path)
        return false, nil, nil, "failed to popen CLI process on Windows"
    end

    self._process = stdout_handle
    self._stdin_pipe_path = stdin_pipe_path

    return true, stdin_handle, stdout_handle, nil
end

-- ---------------------------------------------------------------------------
-- Internal: handler setup
-- ---------------------------------------------------------------------------

--- Set up JSON-RPC handlers for server-initiated requests and notifications.
function CopilotClient:_setup_handlers()
    -- session.event notification
    self._rpc_client:set_request_handler("session.event", function(params)
        self:_handle_session_event(params)
        return nil, nil
    end)

    -- session.lifecycle notification
    self._rpc_client:set_request_handler("session.lifecycle", function(params)
        -- Lifecycle events are informational; could add handlers here
        return nil, nil
    end)

    -- tool.call request
    self._rpc_client:set_request_handler("tool.call", function(params)
        return self:_handle_tool_call(params)
    end)

    -- permission.request
    self._rpc_client:set_request_handler("permission.request", function(params)
        return self:_handle_permission_request(params)
    end)

    -- userInput.request
    self._rpc_client:set_request_handler("userInput.request", function(params)
        return self:_handle_user_input_request(params)
    end)

    -- hooks.invoke
    self._rpc_client:set_request_handler("hooks.invoke", function(params)
        return self:_handle_hooks_invoke(params)
    end)
end

--- Dispatch a session event to the appropriate session.
function CopilotClient:_handle_session_event(params)
    if not params or not params.sessionId then
        return
    end
    local session = self._sessions[params.sessionId]
    if session then
        session:_dispatch_event(params.event)
    end
end

--- Handle a tool call request from the server.
function CopilotClient:_handle_tool_call(params)
    if not params or not params.sessionId or not params.toolCallId or not params.toolName then
        return nil, { code = -32602, message = "invalid tool call payload" }
    end

    local session = self._sessions[params.sessionId]
    if not session then
        return nil, { code = -32602, message = "unknown session " .. tostring(params.sessionId) }
    end

    local handler = session:_get_tool_handler(params.toolName)
    if not handler then
        return {
            result = {
                textResultForLlm = string.format(
                    "Tool '%s' is not supported by this client instance.", params.toolName
                ),
                resultType    = "failure",
                error         = string.format("tool '%s' not supported", params.toolName),
                toolTelemetry = {},
            },
        }, nil
    end

    -- Execute the tool handler
    local invocation = {
        sessionId  = params.sessionId,
        toolCallId = params.toolCallId,
        toolName   = params.toolName,
        arguments  = params.arguments,
    }

    local ok, result = pcall(handler, invocation)
    if not ok then
        return {
            result = {
                textResultForLlm = "Invoking this tool produced an error. Detailed information is not available.",
                resultType    = "failure",
                error         = tostring(result),
                toolTelemetry = {},
            },
        }, nil
    end

    -- Normalize result
    if type(result) == "string" then
        result = {
            textResultForLlm = result,
            resultType       = "success",
        }
    elseif type(result) ~= "table" then
        result = {
            textResultForLlm = tostring(result or ""),
            resultType       = "success",
        }
    end

    -- Ensure required fields
    if not result.resultType then
        result.resultType = "success"
    end
    if not result.textResultForLlm then
        result.textResultForLlm = ""
    end

    return { result = result }, nil
end

--- Handle a permission request from the server.
function CopilotClient:_handle_permission_request(params)
    if not params or not params.sessionId then
        return nil, { code = -32602, message = "invalid permission request payload" }
    end

    local session = self._sessions[params.sessionId]
    if not session then
        return nil, { code = -32602, message = "unknown session " .. tostring(params.sessionId) }
    end

    local handler = session:_get_permission_handler()
    if not handler then
        return {
            result = {
                kind = "denied-no-approval-rule-and-could-not-request-from-user",
            },
        }, nil
    end

    local permission_request = params.permissionRequest or {}
    local invocation = { sessionId = params.sessionId }

    local ok, result = pcall(handler, permission_request, invocation)
    if not ok then
        return {
            result = {
                kind = "denied-no-approval-rule-and-could-not-request-from-user",
            },
        }, nil
    end

    return { result = result }, nil
end

--- Handle a user input request from the server.
function CopilotClient:_handle_user_input_request(params)
    if not params or not params.sessionId or not params.question then
        return nil, { code = -32602, message = "invalid user input request payload" }
    end

    local session = self._sessions[params.sessionId]
    if not session then
        return nil, { code = -32602, message = "unknown session " .. tostring(params.sessionId) }
    end

    local handler = session:_get_user_input_handler()
    if not handler then
        return nil, { code = -32603, message = "no user input handler registered" }
    end

    local request = {
        question      = params.question,
        choices       = params.choices,
        allowFreeform = params.allowFreeform,
    }
    local invocation = { sessionId = params.sessionId }

    local ok, result = pcall(handler, request, invocation)
    if not ok then
        return nil, { code = -32603, message = tostring(result) }
    end

    return {
        answer      = result.answer or "",
        wasFreeform = result.wasFreeform or false,
    }, nil
end

--- Handle a hooks invocation from the server.
function CopilotClient:_handle_hooks_invoke(params)
    if not params or not params.sessionId or not params.hookType then
        return nil, { code = -32602, message = "invalid hooks invoke payload" }
    end

    local session = self._sessions[params.sessionId]
    if not session then
        return nil, { code = -32602, message = "unknown session " .. tostring(params.sessionId) }
    end

    local output, err = session:_handle_hooks_invoke(params.hookType, params.input)
    if err then
        return nil, { code = -32603, message = tostring(err) }
    end

    local result = {}
    if output then
        result.output = output
    end
    return result, nil
end

-- ---------------------------------------------------------------------------
-- Internal: request building
-- ---------------------------------------------------------------------------

--- Build the request body for session.create.
function CopilotClient:_build_create_session_request(config)
    local req = {}

    if config.model then req.model = config.model end
    if config.sessionId then req.sessionId = config.sessionId end
    if config.reasoningEffort then req.reasoningEffort = config.reasoningEffort end
    if config.configDir then req.configDir = config.configDir end
    if config.workingDirectory then req.workingDirectory = config.workingDirectory end
    if config.systemMessage then req.systemMessage = config.systemMessage end
    if config.provider then req.provider = config.provider end

    -- Tools: serialize without the handler function
    if config.tools and #config.tools > 0 then
        local tool_defs = {}
        for _, tool in ipairs(config.tools) do
            table.insert(tool_defs, {
                name        = tool.name,
                description = tool.description,
                parameters  = tool.parameters,
            })
        end
        req.tools = tool_defs
    end

    if config.availableTools then req.availableTools = config.availableTools end
    if config.excludedTools then req.excludedTools = config.excludedTools end
    if config.mcpServers then req.mcpServers = config.mcpServers end
    if config.customAgents then req.customAgents = config.customAgents end
    if config.skillDirectories then req.skillDirectories = config.skillDirectories end
    if config.disabledSkills then req.disabledSkills = config.disabledSkills end
    if config.infiniteSessions then req.infiniteSessions = config.infiniteSessions end

    if config.streaming then req.streaming = true end
    if config.onPermissionRequest then req.requestPermission = true end
    if config.onUserInputRequest then req.requestUserInput = true end

    if config.hooks then
        local h = config.hooks
        if h.onPreToolUse or h.onPostToolUse or h.onUserPromptSubmitted
            or h.onSessionStart or h.onSessionEnd or h.onErrorOccurred then
            req.hooks = true
        end
    end

    return req
end

--- Build the request body for session.resume.
function CopilotClient:_build_resume_session_request(session_id, config)
    local req = { sessionId = session_id }

    if config.model then req.model = config.model end
    if config.reasoningEffort then req.reasoningEffort = config.reasoningEffort end
    if config.configDir then req.configDir = config.configDir end
    if config.workingDirectory then req.workingDirectory = config.workingDirectory end
    if config.systemMessage then req.systemMessage = config.systemMessage end
    if config.provider then req.provider = config.provider end

    if config.tools and #config.tools > 0 then
        local tool_defs = {}
        for _, tool in ipairs(config.tools) do
            table.insert(tool_defs, {
                name        = tool.name,
                description = tool.description,
                parameters  = tool.parameters,
            })
        end
        req.tools = tool_defs
    end

    if config.availableTools then req.availableTools = config.availableTools end
    if config.excludedTools then req.excludedTools = config.excludedTools end
    if config.mcpServers then req.mcpServers = config.mcpServers end
    if config.customAgents then req.customAgents = config.customAgents end
    if config.skillDirectories then req.skillDirectories = config.skillDirectories end
    if config.disabledSkills then req.disabledSkills = config.disabledSkills end
    if config.infiniteSessions then req.infiniteSessions = config.infiniteSessions end

    if config.streaming then req.streaming = true end
    if config.onPermissionRequest then req.requestPermission = true end
    if config.onUserInputRequest then req.requestUserInput = true end
    if config.disableResume then req.disableResume = true end

    if config.hooks then
        local h = config.hooks
        if h.onPreToolUse or h.onPostToolUse or h.onUserPromptSubmitted
            or h.onSessionStart or h.onSessionEnd or h.onErrorOccurred then
            req.hooks = true
        end
    end

    return req
end

-- ---------------------------------------------------------------------------
-- Internal: protocol version verification
-- ---------------------------------------------------------------------------

--- Verify that the server protocol version matches the SDK expectation.
-- @return boolean success
-- @return string|nil error
function CopilotClient:_verify_protocol_version()
    local expected = sdk_protocol_version.get()
    local result, err = self:ping("")
    if err then
        return false, "ping failed during protocol verification: " .. tostring(err)
    end

    if not result then
        return false, "ping returned nil result"
    end

    local server_version = result.protocolVersion
    if server_version == nil then
        return false, string.format(
            "SDK protocol version mismatch: SDK expects version %d, but server does not report a protocol version. Please update your server to ensure compatibility.",
            expected
        )
    end

    if server_version ~= expected then
        return false, string.format(
            "SDK protocol version mismatch: SDK expects version %d, but server reports version %d. Please update your SDK or server to ensure compatibility.",
            expected, server_version
        )
    end

    return true, nil
end

return CopilotClient
