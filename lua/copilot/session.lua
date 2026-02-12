--- CopilotSession: represents a single conversation session with the Copilot CLI.
--
-- Sessions maintain conversation state, handle events, and manage tool execution.
-- Sessions are created via CopilotClient:create_session() or resumed via
-- CopilotClient:resume_session().
--
-- Usage:
--   local session = client:create_session({ model = "gpt-4" })
--   session:on(function(event) print(event.type) end)
--   session:send({ prompt = "Hello!" })
--   session:destroy()

local cjson = require("cjson")
local types = require("copilot.types")

-- ---------------------------------------------------------------------------
-- CopilotSession class
-- ---------------------------------------------------------------------------

local CopilotSession = {}
CopilotSession.__index = CopilotSession

--- Create a new CopilotSession (internal, called by CopilotClient).
-- @param session_id string      The unique session ID
-- @param rpc_client JsonRpcClient  The JSON-RPC client
-- @param workspace_path string|nil  The workspace path for infinite sessions
-- @return CopilotSession
function CopilotSession.new(session_id, rpc_client, workspace_path)
    local self = setmetatable({}, CopilotSession)

    self.session_id        = session_id
    self.workspace_path    = workspace_path or ""
    self._rpc_client       = rpc_client
    self._handlers         = {}           -- array of {id=number, fn=function}
    self._next_handler_id  = 1
    self._tool_handlers    = {}           -- toolName -> handler function
    self._permission_handler = nil        -- function or nil
    self._user_input_handler = nil        -- function or nil
    self._hooks            = nil          -- SessionHooks table or nil

    return self
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Send a message to this session.
-- @param options table  MessageOptions with fields: prompt, attachments, mode
-- @return string|nil messageId
-- @return string|nil error
function CopilotSession:send(options)
    options = options or {}
    local req = {
        sessionId   = self.session_id,
        prompt      = options.prompt or "",
        attachments = options.attachments,
        mode        = options.mode,
    }

    local result, err = self._rpc_client:request("session.send", req)
    if err then
        return nil, "failed to send message: " .. tostring(err)
    end

    if result and result.messageId then
        return result.messageId, nil
    end
    return nil, nil
end

--- Send a message and wait until the session becomes idle.
-- Returns the final assistant message event, or nil if none was received.
-- @param options table     MessageOptions
-- @param timeout number|nil  Timeout in seconds (default 60)
-- @return table|nil  The last assistant.message SessionEvent
-- @return string|nil error
function CopilotSession:send_and_wait(options, timeout)
    timeout = timeout or 60

    local last_assistant_message = nil
    local idle_received = false
    local error_received = nil

    -- Subscribe to events
    local unsubscribe = self:on(function(event)
        if event.type == types.SessionEventType.ASSISTANT_MESSAGE then
            last_assistant_message = event
        elseif event.type == types.SessionEventType.SESSION_IDLE then
            idle_received = true
        elseif event.type == types.SessionEventType.SESSION_ERROR then
            local msg = "session error"
            if event.data and event.data.message then
                msg = event.data.message
            end
            error_received = msg
        end
    end)

    -- Send the message
    local _, send_err = self:send(options)
    if send_err then
        unsubscribe()
        return nil, send_err
    end

    -- Wait for idle or error, polling the read loop
    local start_time = os.time()
    while not idle_received and not error_received do
        -- Check timeout
        if os.time() - start_time >= timeout then
            unsubscribe()
            return nil, "timeout waiting for session.idle"
        end

        -- Drive the read loop for one message
        if self._rpc_client and self._rpc_client._read_one_message then
            local ok, read_err = self._rpc_client:_read_one_message()
            if not ok then
                unsubscribe()
                return nil, "read error: " .. tostring(read_err)
            end
        else
            -- Fallback: small sleep to avoid busy-waiting
            -- In a real async environment, this would yield to the event loop
            local sleep_until = os.clock() + 0.01
            while os.clock() < sleep_until do end
        end
    end

    unsubscribe()

    if error_received then
        return nil, "session error: " .. tostring(error_received)
    end

    return last_assistant_message, nil
end

--- Subscribe to events from this session.
-- Returns an unsubscribe function.
-- @param handler function(event)  Event handler callback
-- @return function  Call to unsubscribe
function CopilotSession:on(handler)
    local id = self._next_handler_id
    self._next_handler_id = self._next_handler_id + 1

    table.insert(self._handlers, { id = id, fn = handler })

    -- Return unsubscribe function
    return function()
        for i, h in ipairs(self._handlers) do
            if h.id == id then
                table.remove(self._handlers, i)
                break
            end
        end
    end
end

--- Retrieve all events and messages from this session's history.
-- @return table|nil  Array of SessionEvent
-- @return string|nil error
function CopilotSession:get_messages()
    local result, err = self._rpc_client:request("session.getMessages", {
        sessionId = self.session_id,
    })
    if err then
        return nil, "failed to get messages: " .. tostring(err)
    end

    if result and result.events then
        return result.events, nil
    end
    return {}, nil
end

--- Destroy this session and release resources.
-- @return boolean success
-- @return string|nil error
function CopilotSession:destroy()
    local _, err = self._rpc_client:request("session.destroy", {
        sessionId = self.session_id,
    })
    if err then
        return false, "failed to destroy session: " .. tostring(err)
    end

    -- Clear all handlers
    self._handlers           = {}
    self._tool_handlers      = {}
    self._permission_handler = nil
    self._user_input_handler = nil
    self._hooks              = nil

    return true, nil
end

--- Abort the currently processing message in this session.
-- @return boolean success
-- @return string|nil error
function CopilotSession:abort()
    local _, err = self._rpc_client:request("session.abort", {
        sessionId = self.session_id,
    })
    if err then
        return false, "failed to abort session: " .. tostring(err)
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- Internal: event dispatch
-- ---------------------------------------------------------------------------

--- Dispatch an event to all registered handlers.
-- @param event table  SessionEvent
function CopilotSession:_dispatch_event(event)
    if not event then return end

    -- Copy handler list to avoid issues if handlers unsubscribe during iteration
    local handlers = {}
    for _, h in ipairs(self._handlers) do
        table.insert(handlers, h.fn)
    end

    for _, fn in ipairs(handlers) do
        local ok, err = pcall(fn, event)
        if not ok then
            io.stderr:write(string.format(
                "Error in session event handler: %s\n", tostring(err)
            ))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Internal: tool registration
-- ---------------------------------------------------------------------------

--- Register tool handlers for this session.
-- @param tools table|nil  Array of Tool tables (with handler field)
function CopilotSession:_register_tools(tools)
    self._tool_handlers = {}
    if not tools then return end

    for _, tool in ipairs(tools) do
        if tool.name and tool.name ~= "" and tool.handler then
            self._tool_handlers[tool.name] = tool.handler
        end
    end
end

--- Get a registered tool handler by name.
-- @param name string
-- @return function|nil
function CopilotSession:_get_tool_handler(name)
    return self._tool_handlers[name]
end

-- ---------------------------------------------------------------------------
-- Internal: permission handler
-- ---------------------------------------------------------------------------

--- Register a permission handler.
-- @param handler function(request, invocation) -> PermissionRequestResult
function CopilotSession:_register_permission_handler(handler)
    self._permission_handler = handler
end

--- Get the registered permission handler.
-- @return function|nil
function CopilotSession:_get_permission_handler()
    return self._permission_handler
end

-- ---------------------------------------------------------------------------
-- Internal: user input handler
-- ---------------------------------------------------------------------------

--- Register a user input handler.
-- @param handler function(request, invocation) -> UserInputResponse
function CopilotSession:_register_user_input_handler(handler)
    self._user_input_handler = handler
end

--- Get the registered user input handler.
-- @return function|nil
function CopilotSession:_get_user_input_handler()
    return self._user_input_handler
end

-- ---------------------------------------------------------------------------
-- Internal: hooks
-- ---------------------------------------------------------------------------

--- Register hooks for this session.
-- @param hooks table  SessionHooks
function CopilotSession:_register_hooks(hooks)
    self._hooks = hooks
end

--- Get the registered hooks.
-- @return table|nil
function CopilotSession:_get_hooks()
    return self._hooks
end

--- Handle a hooks invocation from the server.
-- @param hook_type string    The hook type (e.g. "preToolUse", "postToolUse")
-- @param input table         The hook input data
-- @return table|nil output
-- @return string|nil error
function CopilotSession:_handle_hooks_invoke(hook_type, input)
    local hooks = self._hooks
    if not hooks then
        return nil, nil
    end

    local invocation = { sessionId = self.session_id }

    if hook_type == "preToolUse" then
        if not hooks.onPreToolUse then return nil, nil end
        local ok, result = pcall(hooks.onPreToolUse, input, invocation)
        if not ok then return nil, tostring(result) end
        return result, nil

    elseif hook_type == "postToolUse" then
        if not hooks.onPostToolUse then return nil, nil end
        local ok, result = pcall(hooks.onPostToolUse, input, invocation)
        if not ok then return nil, tostring(result) end
        return result, nil

    elseif hook_type == "userPromptSubmitted" then
        if not hooks.onUserPromptSubmitted then return nil, nil end
        local ok, result = pcall(hooks.onUserPromptSubmitted, input, invocation)
        if not ok then return nil, tostring(result) end
        return result, nil

    elseif hook_type == "sessionStart" then
        if not hooks.onSessionStart then return nil, nil end
        local ok, result = pcall(hooks.onSessionStart, input, invocation)
        if not ok then return nil, tostring(result) end
        return result, nil

    elseif hook_type == "sessionEnd" then
        if not hooks.onSessionEnd then return nil, nil end
        local ok, result = pcall(hooks.onSessionEnd, input, invocation)
        if not ok then return nil, tostring(result) end
        return result, nil

    elseif hook_type == "errorOccurred" then
        if not hooks.onErrorOccurred then return nil, nil end
        local ok, result = pcall(hooks.onErrorOccurred, input, invocation)
        if not ok then return nil, tostring(result) end
        return result, nil

    else
        return nil, "unknown hook type: " .. tostring(hook_type)
    end
end

return CopilotSession
