--- Helper for defining tools with automatic result normalization.
--
-- Usage:
--   local define_tool = require("copilot.define_tool")
--
--   local weather_tool = define_tool("get_weather", {
--       description = "Get weather for a city",
--       parameters = {
--           type = "object",
--           properties = {
--               city = { type = "string", description = "City name" },
--               unit = { type = "string", description = "celsius or fahrenheit" },
--           },
--           required = { "city" },
--       },
--       handler = function(args, invocation)
--           return string.format("Weather in %s: 22 degrees %s",
--               args.city or "unknown", args.unit or "celsius")
--       end,
--   })

local cjson = require("cjson")
local types = require("copilot.types")

--- Normalize a tool handler return value into a ToolResult table.
-- Strings pass through directly, ToolResult tables pass through,
-- other values are JSON-serialized.
-- @param result any  The raw return value from the handler
-- @return table ToolResult
local function normalize_result(result)
    if result == nil then
        return types.ToolResult({
            textResultForLlm = "",
            resultType       = "success",
        })
    end

    -- If it is already a ToolResult-shaped table (has resultType field)
    if type(result) == "table" and result.resultType then
        return result
    end

    -- Strings pass through directly
    if type(result) == "string" then
        return types.ToolResult({
            textResultForLlm = result,
            resultType       = "success",
        })
    end

    -- Everything else gets JSON-serialized
    local ok, json_str = pcall(cjson.encode, result)
    if not ok then
        return types.ToolResult({
            textResultForLlm = tostring(result),
            resultType       = "success",
        })
    end

    return types.ToolResult({
        textResultForLlm = json_str,
        resultType       = "success",
    })
end

--- Define a tool with automatic result normalization.
--
-- The handler receives the parsed arguments table and a ToolInvocation table.
-- It can return:
--   - A string (becomes textResultForLlm)
--   - A ToolResult table (passed through as-is)
--   - Any other value (JSON-serialized to textResultForLlm)
--   - nil (empty success result)
--
-- If the handler raises an error, a failure ToolResult is returned automatically.
--
-- @param name string             Tool name
-- @param opts table with fields:
--   - description: string        Tool description
--   - parameters: table|nil      JSON Schema for arguments
--   - handler: function(args, invocation) -> any
-- @return table Tool              A Tool table ready for use in SessionConfig
local function define_tool(name, opts)
    opts = opts or {}

    local raw_handler = opts.handler
    if not raw_handler then
        error("define_tool: handler is required")
    end

    -- Wrap the handler to normalize results and catch errors
    local wrapped_handler = function(invocation)
        -- Parse arguments if they are a string (defensive)
        local args = invocation.arguments
        if type(args) == "string" then
            local ok, parsed = pcall(cjson.decode, args)
            if ok then
                args = parsed
            end
        end
        args = args or {}

        -- Call the user handler
        local ok, result_or_err = pcall(raw_handler, args, invocation)
        if not ok then
            return types.ToolResult({
                textResultForLlm = "Invoking this tool produced an error. Detailed information is not available.",
                resultType       = "failure",
                error            = tostring(result_or_err),
                toolTelemetry    = {},
            })
        end

        return normalize_result(result_or_err)
    end

    return types.Tool({
        name        = name,
        description = opts.description or "",
        parameters  = opts.parameters,
        handler     = wrapped_handler,
    })
end

return define_tool
