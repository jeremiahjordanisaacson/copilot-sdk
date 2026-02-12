--- JSON-RPC 2.0 client for Content-Length header framed stdio transport.
-- Reads from a file handle (stdout of the CLI process) and writes to another
-- (stdin of the CLI process). Uses coroutines for cooperative async I/O.

local cjson = require("cjson")

-- ---------------------------------------------------------------------------
-- UUID v4 generator (no external dependency)
-- ---------------------------------------------------------------------------

local random = math.random

--- Generate a UUID v4 string.
-- @return string A UUID in the form xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
local function generate_uuid()
    -- Seed once per process
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
        return string.format("%x", v)
    end))
end

-- ---------------------------------------------------------------------------
-- JsonRpcClient class
-- ---------------------------------------------------------------------------

local JsonRpcClient = {}
JsonRpcClient.__index = JsonRpcClient

--- Create a new JSON-RPC 2.0 client.
-- @param write_handle file-like object with a :write() method (stdin pipe)
-- @param read_handle  file-like object with a :read() method  (stdout pipe)
-- @return JsonRpcClient
function JsonRpcClient.new(write_handle, read_handle)
    local self = setmetatable({}, JsonRpcClient)
    self._writer           = write_handle
    self._reader           = read_handle
    self._pending_requests = {}       -- id -> {co=coroutine, result=nil}
    self._request_handlers = {}       -- method -> function(params) -> result, err
    self._running          = false
    self._stopped          = false
    return self
end

--- Register a handler for incoming requests / notifications from the server.
-- @param method string  The JSON-RPC method name
-- @param handler function(params) -> result_table|nil, error_table|nil
function JsonRpcClient:set_request_handler(method, handler)
    self._request_handlers[method] = handler
end

--- Send a JSON-RPC 2.0 request and return the result.
-- MUST be called from inside the read loop (or a coroutine yielding back to it).
-- For the simple synchronous case, use request_sync() which drives the read loop.
-- @param method string
-- @param params table
-- @return table|nil result
-- @return string|nil error message
function JsonRpcClient:request(method, params)
    local id = generate_uuid()

    local request = {
        jsonrpc = "2.0",
        id      = id,
        method  = method,
        params  = params or {},
    }

    local ok, err = self:_send_message(request)
    if not ok then
        return nil, "failed to send request: " .. tostring(err)
    end

    -- Create an entry so the read loop can fill in the response
    self._pending_requests[id] = { result = nil, error = nil, done = false }

    -- If we are inside a coroutine, yield until the response arrives
    local co = coroutine.running()
    if co then
        self._pending_requests[id].co = co
        -- Yield control back to the read loop driver
        local res_result, res_err = coroutine.yield()
        return res_result, res_err
    end

    -- Otherwise, spin the read loop inline (synchronous fallback)
    while not self._pending_requests[id].done do
        local read_ok, read_err = self:_read_one_message()
        if not read_ok then
            self._pending_requests[id] = nil
            return nil, "read error while waiting for response: " .. tostring(read_err)
        end
    end

    local entry = self._pending_requests[id]
    self._pending_requests[id] = nil
    if entry.error then
        return nil, entry.error
    end
    return entry.result, nil
end

--- Send a JSON-RPC 2.0 notification (fire and forget, no response expected).
-- @param method string
-- @param params table
-- @return boolean success
-- @return string|nil error message
function JsonRpcClient:notify(method, params)
    local notification = {
        jsonrpc = "2.0",
        method  = method,
        params  = params or {},
    }
    return self:_send_message(notification)
end

--- Run the read loop. Blocks until the connection is closed or stop() is called.
-- Dispatches incoming responses to pending requests and incoming requests/notifications
-- to registered handlers.
function JsonRpcClient:run()
    self._running = true
    while self._running do
        local ok, err = self:_read_one_message()
        if not ok then
            if self._running then
                io.stderr:write("JsonRpcClient read error: " .. tostring(err) .. "\n")
            end
            break
        end
    end
    self._running = false

    -- Wake up any pending requests with an error
    for id, entry in pairs(self._pending_requests) do
        entry.done = true
        entry.error = "client stopped"
        if entry.co then
            local ok, err = coroutine.resume(entry.co, nil, "client stopped")
            if not ok then
                io.stderr:write("coroutine resume error: " .. tostring(err) .. "\n")
            end
        end
    end
    self._pending_requests = {}
end

--- Stop the read loop.
function JsonRpcClient:stop()
    self._running = false
    self._stopped = true
end

--- Check whether the client is currently running.
-- @return boolean
function JsonRpcClient:is_running()
    return self._running
end

-- ---------------------------------------------------------------------------
-- Internal: wire protocol
-- ---------------------------------------------------------------------------

--- Write a JSON-RPC message with Content-Length framing.
-- @param message table  The message to encode and send
-- @return boolean success
-- @return string|nil error
function JsonRpcClient:_send_message(message)
    local ok_enc, data = pcall(cjson.encode, message)
    if not ok_enc then
        return false, "JSON encode error: " .. tostring(data)
    end

    local frame = string.format("Content-Length: %d\r\n\r\n%s", #data, data)
    local ok, err = pcall(function()
        self._writer:write(frame)
        self._writer:flush()
    end)
    if not ok then
        return false, "write error: " .. tostring(err)
    end
    return true, nil
end

--- Read exactly n bytes from the reader.
-- @param n number
-- @return string|nil data
-- @return string|nil error
function JsonRpcClient:_read_bytes(n)
    local data = self._reader:read(n)
    if data == nil then
        return nil, "EOF"
    end
    if #data < n then
        -- Some Lua I/O implementations may return partial reads; accumulate.
        local parts = { data }
        local got = #data
        while got < n do
            local chunk = self._reader:read(n - got)
            if chunk == nil then
                return nil, "EOF during read"
            end
            parts[#parts + 1] = chunk
            got = got + #chunk
        end
        data = table.concat(parts)
    end
    return data, nil
end

--- Read one line (up to and including \n) from the reader.
-- @return string|nil line
-- @return string|nil error
function JsonRpcClient:_read_line()
    local line = self._reader:read("*l")
    if line == nil then
        return nil, "EOF"
    end
    return line, nil
end

--- Read one Content-Length framed JSON-RPC message and dispatch it.
-- @return boolean success
-- @return string|nil error
function JsonRpcClient:_read_one_message()
    -- Read headers until blank line
    local content_length = 0
    while true do
        local line, err = self:_read_line()
        if not line then
            return false, err or "EOF"
        end

        -- Strip trailing \r if present
        line = line:gsub("\r$", "")

        -- Blank line signals end of headers
        if line == "" then
            break
        end

        -- Parse Content-Length header
        local length = line:match("^Content%-Length:%s*(%d+)")
        if length then
            content_length = tonumber(length)
        end
    end

    if content_length == 0 then
        -- Empty frame, skip
        return true, nil
    end

    -- Read the message body
    local body, err = self:_read_bytes(content_length)
    if not body then
        return false, "failed to read body: " .. tostring(err)
    end

    -- Decode JSON
    local ok_dec, msg = pcall(cjson.decode, body)
    if not ok_dec then
        return false, "JSON decode error: " .. tostring(msg)
    end

    -- Dispatch based on whether it is a request/notification or a response
    if msg.method and msg.method ~= "" then
        self:_handle_incoming_request(msg)
    elseif msg.id then
        self:_handle_response(msg)
    end

    return true, nil
end

--- Handle an incoming response to one of our pending requests.
-- @param response table
function JsonRpcClient:_handle_response(response)
    local id = response.id
    local entry = self._pending_requests[id]
    if not entry then
        return
    end

    if response.error then
        local err_msg = string.format(
            "JSON-RPC Error %s: %s",
            tostring(response.error.code or "?"),
            tostring(response.error.message or "unknown")
        )
        entry.error = err_msg
    else
        entry.result = response.result
    end
    entry.done = true

    -- If a coroutine is waiting, resume it
    if entry.co then
        self._pending_requests[id] = nil
        local ok, resume_err = coroutine.resume(entry.co, entry.result, entry.error)
        if not ok then
            io.stderr:write("coroutine resume error: " .. tostring(resume_err) .. "\n")
        end
    end
end

--- Handle an incoming request or notification from the server.
-- @param request table with fields: jsonrpc, id (may be nil), method, params
function JsonRpcClient:_handle_incoming_request(request)
    local handler = self._request_handlers[request.method]
    local is_call = (request.id ~= nil)

    if not handler then
        if is_call then
            self:_send_error_response(
                request.id,
                -32601,
                "Method not found: " .. tostring(request.method)
            )
        end
        return
    end

    -- Execute the handler
    local ok, result_or_err, rpc_err = pcall(handler, request.params)

    if not ok then
        -- Handler threw an error
        if is_call then
            self:_send_error_response(
                request.id,
                -32603,
                "Handler error: " .. tostring(result_or_err)
            )
        end
        return
    end

    if is_call then
        if rpc_err then
            self:_send_error_response(
                request.id,
                rpc_err.code or -32603,
                rpc_err.message or "internal error"
            )
        else
            self:_send_result_response(request.id, result_or_err)
        end
    end
end

--- Send a successful JSON-RPC response.
-- @param id string|number  The request ID
-- @param result table|nil  The result payload
function JsonRpcClient:_send_result_response(id, result)
    local response = {
        jsonrpc = "2.0",
        id      = id,
        result  = result or cjson.null,
    }
    self:_send_message(response)
end

--- Send an error JSON-RPC response.
-- @param id string|number  The request ID
-- @param code number       Error code
-- @param message string    Error message
function JsonRpcClient:_send_error_response(id, code, message)
    local response = {
        jsonrpc = "2.0",
        id      = id,
        error   = {
            code    = code,
            message = message,
        },
    }
    self:_send_message(response)
end

return JsonRpcClient
