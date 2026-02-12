package = "copilot-sdk-supercharged"
version = "0.1.0-1"

source = {
    url = "https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged",
    tag = "lua-v0.1.0",
}

description = {
    summary = "Lua Supercharged SDK for the GitHub Copilot CLI",
    detailed = [[
        A Lua SDK for interacting with the GitHub Copilot CLI server.
        Communicates via JSON-RPC 2.0 over stdio using Content-Length header framing.
        Supports session management, custom tools, permission handling, user input,
        and hook invocations.
    ]],
    homepage = "https://github.com/jeremiahjordanisaacson/copilot-sdk-supercharged",
    license = "MIT",
}

dependencies = {
    "lua >= 5.1",
    "lua-cjson >= 2.1.0",
}

build = {
    type = "builtin",
    modules = {
        ["copilot.sdk_protocol_version"] = "copilot/sdk_protocol_version.lua",
        ["copilot.types"]                = "copilot/types.lua",
        ["copilot.json_rpc_client"]      = "copilot/json_rpc_client.lua",
        ["copilot.client"]               = "copilot/client.lua",
        ["copilot.session"]              = "copilot/session.lua",
        ["copilot.define_tool"]          = "copilot/define_tool.lua",
    },
}
