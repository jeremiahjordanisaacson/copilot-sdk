#!/usr/bin/env lua
--- Basic example demonstrating the Copilot Lua SDK.
--
-- This example:
--   1. Creates a CopilotClient and connects to the CLI server
--   2. Defines a custom tool (lookup_fact)
--   3. Creates a session with the tool registered
--   4. Sends a simple math question and prints the response
--   5. Sends a follow-up that uses the custom tool
--   6. Cleans up

-- Add the parent directory to the module path so we can find the copilot modules
local script_dir = arg[0]:match("(.-)[^/\\]+$") or "./"
package.path = script_dir .. "../?.lua;" .. script_dir .. "../?/init.lua;" .. package.path

local CopilotClient = require("copilot.client")
local define_tool   = require("copilot.define_tool")
local types         = require("copilot.types")

-- ---------------------------------------------------------------------------
-- Define a custom tool
-- ---------------------------------------------------------------------------

local facts = {
    javascript = "JavaScript was created in 10 days by Brendan Eich in 1995.",
    node       = "Node.js lets you run JavaScript outside the browser using the V8 engine.",
    lua        = "Lua was created in 1993 at PUC-Rio in Brazil and means 'moon' in Portuguese.",
    python     = "Python was created by Guido van Rossum and first released in 1991.",
}

local lookup_fact_tool = define_tool("lookup_fact", {
    description = "Returns a fun fact about a given programming topic.",
    parameters = {
        type = "object",
        properties = {
            topic = {
                type        = "string",
                description = "Topic to look up (e.g. 'javascript', 'lua', 'node')",
            },
        },
        required = { "topic" },
    },
    handler = function(args, invocation)
        local topic = (args.topic or ""):lower()
        local fact = facts[topic]
        if fact then
            return fact
        end
        return string.format("No fact stored for '%s'.", args.topic or "unknown")
    end,
})

-- ---------------------------------------------------------------------------
-- Permission handler (auto-approve everything for this example)
-- ---------------------------------------------------------------------------

local function permission_handler(request, invocation)
    print(string.format("[Permission] Session %s requested: %s",
        invocation.sessionId, request.kind or "unknown"))
    return types.PermissionRequestResult({ kind = "approved" })
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main()
    print("Starting Copilot SDK Lua Example")
    print(string.rep("-", 50))

    -- Create client (searches PATH for "copilot" CLI)
    local client = CopilotClient.new({
        logLevel = "info",
    })

    -- Start the client (spawns CLI server)
    local ok, err = client:start()
    if not ok then
        print("ERROR: Failed to start client: " .. tostring(err))
        os.exit(1)
    end
    print("Client started successfully.")

    -- List available models
    local models, models_err = client:list_models()
    if models and not models_err then
        print(string.format("Available models: %d", #models))
        for i, m in ipairs(models) do
            if i <= 5 then
                print(string.format("  - %s (%s)", m.name or m.id, m.id))
            end
        end
        if #models > 5 then
            print(string.format("  ... and %d more", #models - 5))
        end
    end

    -- Create a session with our custom tool
    local session, sess_err = client:create_session({
        tools               = { lookup_fact_tool },
        onPermissionRequest = permission_handler,
    })
    if not session then
        print("ERROR: Failed to create session: " .. tostring(sess_err))
        client:stop()
        os.exit(1)
    end
    print(string.format("Session created: %s", session.session_id))
    print()

    -- Subscribe to all events
    local unsubscribe = session:on(function(event)
        local event_type = event.type or "unknown"
        print(string.format("[Event] %s", event_type))
        if event.data and event.data.content then
            print(string.format("  Content: %s",
                tostring(event.data.content):sub(1, 200)))
        end
    end)

    -- Send a simple message
    print("Sending message: 'What is 2+2?'")
    local response1, err1 = session:send_and_wait({ prompt = "What is 2+2?" })
    if err1 then
        print("ERROR: " .. tostring(err1))
    elseif response1 then
        print(string.format("Response: %s",
            tostring(response1.data and response1.data.content or "(no content)")))
    end
    print()

    -- Send a message that exercises the custom tool
    print("Sending message: 'Use lookup_fact to tell me about lua'")
    local response2, err2 = session:send_and_wait({
        prompt = "Use the lookup_fact tool to tell me about 'lua'",
    })
    if err2 then
        print("ERROR: " .. tostring(err2))
    elseif response2 then
        print(string.format("Response: %s",
            tostring(response2.data and response2.data.content or "(no content)")))
    end
    print()

    -- Unsubscribe from events
    unsubscribe()

    -- Get conversation history
    local messages, msg_err = session:get_messages()
    if messages and not msg_err then
        print(string.format("Conversation history: %d events", #messages))
    end

    -- Clean up
    print("Destroying session...")
    session:destroy()

    print("Stopping client...")
    client:stop()

    print(string.rep("-", 50))
    print("Done!")
end

-- Run
main()
