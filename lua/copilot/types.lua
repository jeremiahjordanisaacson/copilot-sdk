--- Type constructors for the Copilot SDK.
-- All types are represented as plain Lua tables. Constructor functions provide
-- default values and documentation for each field.

local M = {}

-- ---------------------------------------------------------------------------
-- Connection state constants
-- ---------------------------------------------------------------------------

M.ConnectionState = {
    DISCONNECTED = "disconnected",
    CONNECTING   = "connecting",
    CONNECTED    = "connected",
    ERROR        = "error",
}

-- ---------------------------------------------------------------------------
-- Session event type constants
-- ---------------------------------------------------------------------------

M.SessionEventType = {
    ABORT                         = "abort",
    ASSISTANT_INTENT              = "assistant.intent",
    ASSISTANT_MESSAGE             = "assistant.message",
    ASSISTANT_MESSAGE_DELTA       = "assistant.message_delta",
    ASSISTANT_REASONING           = "assistant.reasoning",
    ASSISTANT_REASONING_DELTA     = "assistant.reasoning_delta",
    ASSISTANT_TURN_END            = "assistant.turn_end",
    ASSISTANT_TURN_START          = "assistant.turn_start",
    ASSISTANT_USAGE               = "assistant.usage",
    HOOK_END                      = "hook.end",
    HOOK_START                    = "hook.start",
    PENDING_MESSAGES_MODIFIED     = "pending_messages.modified",
    SESSION_COMPACTION_COMPLETE   = "session.compaction_complete",
    SESSION_COMPACTION_START      = "session.compaction_start",
    SESSION_ERROR                 = "session.error",
    SESSION_HANDOFF               = "session.handoff",
    SESSION_IDLE                  = "session.idle",
    SESSION_INFO                  = "session.info",
    SESSION_MODEL_CHANGE          = "session.model_change",
    SESSION_RESUME                = "session.resume",
    SESSION_SHUTDOWN              = "session.shutdown",
    SESSION_SNAPSHOT_REWIND       = "session.snapshot_rewind",
    SESSION_START                 = "session.start",
    SESSION_TRUNCATION            = "session.truncation",
    SESSION_USAGE_INFO            = "session.usage_info",
    SKILL_INVOKED                 = "skill.invoked",
    SUBAGENT_COMPLETED            = "subagent.completed",
    SUBAGENT_FAILED               = "subagent.failed",
    SUBAGENT_SELECTED             = "subagent.selected",
    SUBAGENT_STARTED              = "subagent.started",
    SYSTEM_MESSAGE                = "system.message",
    TOOL_EXECUTION_COMPLETE       = "tool.execution_complete",
    TOOL_EXECUTION_PARTIAL_RESULT = "tool.execution_partial_result",
    TOOL_EXECUTION_PROGRESS       = "tool.execution_progress",
    TOOL_EXECUTION_START          = "tool.execution_start",
    TOOL_USER_REQUESTED           = "tool.user_requested",
    USER_MESSAGE                  = "user.message",
}

-- ---------------------------------------------------------------------------
-- Session lifecycle event types
-- ---------------------------------------------------------------------------

M.SessionLifecycleEventType = {
    CREATED    = "session.created",
    DELETED    = "session.deleted",
    UPDATED    = "session.updated",
    FOREGROUND = "session.foreground",
    BACKGROUND = "session.background",
}

-- ---------------------------------------------------------------------------
-- Constructor helpers
-- ---------------------------------------------------------------------------

--- Create a new SessionEvent table.
-- SessionEvent is the primary event type dispatched during a session.
-- @param fields table with optional keys: type, id, parentId, timestamp, data, ephemeral
-- @return table SessionEvent
function M.SessionEvent(fields)
    fields = fields or {}
    return {
        type      = fields.type or "",
        id        = fields.id or "",
        parentId  = fields.parentId,        -- optional string
        timestamp = fields.timestamp or "",
        data      = fields.data or {},
        ephemeral = fields.ephemeral,        -- optional boolean
    }
end

--- Create a ToolResult table.
-- @param fields table with optional keys: textResultForLlm, binaryResultsForLlm, resultType, error, sessionLog, toolTelemetry
-- @return table ToolResult
function M.ToolResult(fields)
    fields = fields or {}
    return {
        textResultForLlm    = fields.textResultForLlm or "",
        binaryResultsForLlm = fields.binaryResultsForLlm,   -- optional array
        resultType           = fields.resultType or "success",
        error                = fields.error,                   -- optional string
        sessionLog           = fields.sessionLog,              -- optional string
        toolTelemetry        = fields.toolTelemetry,           -- optional table
    }
end

--- Create a ToolBinaryResult table.
-- @param fields table with keys: data, mimeType, type, description
-- @return table ToolBinaryResult
function M.ToolBinaryResult(fields)
    fields = fields or {}
    return {
        data        = fields.data or "",
        mimeType    = fields.mimeType or "",
        type        = fields.type or "",
        description = fields.description,   -- optional string
    }
end

--- Create a Tool table.
-- @param fields table with keys: name, description, parameters, handler
-- @return table Tool
function M.Tool(fields)
    fields = fields or {}
    return {
        name        = fields.name or "",
        description = fields.description or "",
        parameters  = fields.parameters,    -- optional table (JSON Schema)
        handler     = fields.handler,       -- function(invocation) -> ToolResult, err
    }
end

--- Create a ToolInvocation table.
-- @param fields table with keys: sessionId, toolCallId, toolName, arguments
-- @return table ToolInvocation
function M.ToolInvocation(fields)
    fields = fields or {}
    return {
        sessionId  = fields.sessionId or "",
        toolCallId = fields.toolCallId or "",
        toolName   = fields.toolName or "",
        arguments  = fields.arguments,
    }
end

--- Create a ClientOptions table.
-- @param fields table with optional keys: cliPath, cwd, logLevel, env, githubToken, useLoggedInUser
-- @return table ClientOptions
function M.ClientOptions(fields)
    fields = fields or {}
    return {
        cliPath          = fields.cliPath or "copilot",
        cwd              = fields.cwd,
        logLevel         = fields.logLevel or "info",
        env              = fields.env,            -- optional table of key=value strings
        githubToken      = fields.githubToken,
        useLoggedInUser  = fields.useLoggedInUser, -- optional boolean
        autoStart        = fields.autoStart ~= false,   -- default true
        autoRestart      = fields.autoRestart ~= false,  -- default true
    }
end

--- Create a SessionConfig table.
-- @param fields table with optional keys (see Go SessionConfig)
-- @return table SessionConfig
function M.SessionConfig(fields)
    fields = fields or {}
    return {
        sessionId           = fields.sessionId,
        model               = fields.model,
        reasoningEffort     = fields.reasoningEffort,
        configDir           = fields.configDir,
        tools               = fields.tools,              -- array of Tool
        systemMessage       = fields.systemMessage,      -- {mode, content}
        availableTools      = fields.availableTools,      -- array of strings
        excludedTools       = fields.excludedTools,       -- array of strings
        onPermissionRequest = fields.onPermissionRequest, -- function
        onUserInputRequest  = fields.onUserInputRequest,  -- function
        hooks               = fields.hooks,               -- SessionHooks table
        workingDirectory    = fields.workingDirectory,
        streaming           = fields.streaming,           -- boolean
        provider            = fields.provider,            -- ProviderConfig
        mcpServers          = fields.mcpServers,          -- table
        customAgents        = fields.customAgents,        -- array
        skillDirectories    = fields.skillDirectories,    -- array
        disabledSkills      = fields.disabledSkills,      -- array
        infiniteSessions    = fields.infiniteSessions,    -- InfiniteSessionConfig
    }
end

--- Create a ResumeSessionConfig table.
-- @param fields table
-- @return table ResumeSessionConfig
function M.ResumeSessionConfig(fields)
    fields = fields or {}
    return {
        model               = fields.model,
        reasoningEffort     = fields.reasoningEffort,
        tools               = fields.tools,
        systemMessage       = fields.systemMessage,
        availableTools      = fields.availableTools,
        excludedTools       = fields.excludedTools,
        provider            = fields.provider,
        onPermissionRequest = fields.onPermissionRequest,
        onUserInputRequest  = fields.onUserInputRequest,
        hooks               = fields.hooks,
        workingDirectory    = fields.workingDirectory,
        configDir           = fields.configDir,
        streaming           = fields.streaming,
        disableResume       = fields.disableResume,
        mcpServers          = fields.mcpServers,
        customAgents        = fields.customAgents,
        skillDirectories    = fields.skillDirectories,
        disabledSkills      = fields.disabledSkills,
        infiniteSessions    = fields.infiniteSessions,
    }
end

--- Create a MessageOptions table.
-- @param fields table with keys: prompt, attachments, mode, responseFormat, imageOptions
-- @return table MessageOptions
function M.MessageOptions(fields)
    fields = fields or {}
    return {
        prompt         = fields.prompt or "",
        attachments    = fields.attachments,      -- optional array
        mode           = fields.mode,             -- optional string
        responseFormat = fields.responseFormat,    -- optional string (ResponseFormat constant)
        imageOptions   = fields.imageOptions,     -- optional table (from image_options())
    }
end

--- Create a PingResponse table.
-- @param fields table with keys: message, timestamp, protocolVersion
-- @return table PingResponse
function M.PingResponse(fields)
    fields = fields or {}
    return {
        message         = fields.message or "",
        timestamp       = fields.timestamp or 0,
        protocolVersion = fields.protocolVersion,   -- optional number
    }
end

--- Create a GetStatusResponse table.
-- @param fields table with keys: version, protocolVersion
-- @return table GetStatusResponse
function M.GetStatusResponse(fields)
    fields = fields or {}
    return {
        version         = fields.version or "",
        protocolVersion = fields.protocolVersion or 0,
    }
end

--- Create a GetAuthStatusResponse table.
-- @param fields table
-- @return table GetAuthStatusResponse
function M.GetAuthStatusResponse(fields)
    fields = fields or {}
    return {
        isAuthenticated = fields.isAuthenticated or false,
        authType        = fields.authType,
        host            = fields.host,
        login           = fields.login,
        statusMessage   = fields.statusMessage,
    }
end

--- Create a ModelInfo table.
-- @param fields table
-- @return table ModelInfo
function M.ModelInfo(fields)
    fields = fields or {}
    return {
        id                        = fields.id or "",
        name                      = fields.name or "",
        capabilities              = fields.capabilities or {},
        policy                    = fields.policy,
        billing                   = fields.billing,
        supportedReasoningEfforts = fields.supportedReasoningEfforts,
        defaultReasoningEffort    = fields.defaultReasoningEffort,
    }
end

--- Create a SessionMetadata table.
-- @param fields table
-- @return table SessionMetadata
function M.SessionMetadata(fields)
    fields = fields or {}
    return {
        sessionId    = fields.sessionId or "",
        startTime    = fields.startTime or "",
        modifiedTime = fields.modifiedTime or "",
        summary      = fields.summary,
        isRemote     = fields.isRemote or false,
    }
end

--- Create a PermissionRequest table.
-- @param fields table with keys: kind, toolCallId, extra
-- @return table PermissionRequest
function M.PermissionRequest(fields)
    fields = fields or {}
    return {
        kind       = fields.kind or "",
        toolCallId = fields.toolCallId,
        extra      = fields.extra,
    }
end

--- Create a PermissionRequestResult table.
-- @param fields table with keys: kind, rules
-- @return table PermissionRequestResult
function M.PermissionRequestResult(fields)
    fields = fields or {}
    return {
        kind  = fields.kind or "",
        rules = fields.rules,
    }
end

--- Create a UserInputRequest table.
-- @param fields table with keys: question, choices, allowFreeform
-- @return table UserInputRequest
function M.UserInputRequest(fields)
    fields = fields or {}
    return {
        question      = fields.question or "",
        choices       = fields.choices,
        allowFreeform = fields.allowFreeform,
    }
end

--- Create a UserInputResponse table.
-- @param fields table with keys: answer, wasFreeform
-- @return table UserInputResponse
function M.UserInputResponse(fields)
    fields = fields or {}
    return {
        answer      = fields.answer or "",
        wasFreeform = fields.wasFreeform or false,
    }
end

--- Create a SessionHooks table.
-- @param fields table with optional function keys
-- @return table SessionHooks
function M.SessionHooks(fields)
    fields = fields or {}
    return {
        onPreToolUse          = fields.onPreToolUse,
        onPostToolUse         = fields.onPostToolUse,
        onUserPromptSubmitted = fields.onUserPromptSubmitted,
        onSessionStart        = fields.onSessionStart,
        onSessionEnd          = fields.onSessionEnd,
        onErrorOccurred       = fields.onErrorOccurred,
    }
end

--- Create a PreToolUseHookInput table.
-- @param fields table
-- @return table
function M.PreToolUseHookInput(fields)
    fields = fields or {}
    return {
        timestamp = fields.timestamp or 0,
        cwd       = fields.cwd or "",
        toolName  = fields.toolName or "",
        toolArgs  = fields.toolArgs,
    }
end

--- Create a PreToolUseHookOutput table.
-- @param fields table
-- @return table
function M.PreToolUseHookOutput(fields)
    fields = fields or {}
    return {
        permissionDecision       = fields.permissionDecision,
        permissionDecisionReason = fields.permissionDecisionReason,
        modifiedArgs             = fields.modifiedArgs,
        additionalContext        = fields.additionalContext,
        suppressOutput           = fields.suppressOutput,
    }
end

--- Create a PostToolUseHookInput table.
-- @param fields table
-- @return table
function M.PostToolUseHookInput(fields)
    fields = fields or {}
    return {
        timestamp  = fields.timestamp or 0,
        cwd        = fields.cwd or "",
        toolName   = fields.toolName or "",
        toolArgs   = fields.toolArgs,
        toolResult = fields.toolResult,
    }
end

--- Create a PostToolUseHookOutput table.
-- @param fields table
-- @return table
function M.PostToolUseHookOutput(fields)
    fields = fields or {}
    return {
        modifiedResult    = fields.modifiedResult,
        additionalContext = fields.additionalContext,
        suppressOutput    = fields.suppressOutput,
    }
end

--- Create a ProviderConfig table.
-- @param fields table with keys: type, wireApi, baseUrl, apiKey, bearerToken, azure
-- @return table ProviderConfig
function M.ProviderConfig(fields)
    fields = fields or {}
    return {
        type        = fields.type,
        wireApi     = fields.wireApi,
        baseUrl     = fields.baseUrl or "",
        apiKey      = fields.apiKey,
        bearerToken = fields.bearerToken,
        azure       = fields.azure,
    }
end

--- Create an InfiniteSessionConfig table.
-- @param fields table with optional keys: enabled, backgroundCompactionThreshold, bufferExhaustionThreshold
-- @return table InfiniteSessionConfig
function M.InfiniteSessionConfig(fields)
    fields = fields or {}
    return {
        enabled                      = fields.enabled,
        backgroundCompactionThreshold = fields.backgroundCompactionThreshold,
        bufferExhaustionThreshold     = fields.bufferExhaustionThreshold,
    }
end

--- Create a SessionLifecycleEvent table.
-- @param fields table with keys: type, sessionId, metadata
-- @return table SessionLifecycleEvent
function M.SessionLifecycleEvent(fields)
    fields = fields or {}
    return {
        type      = fields.type or "",
        sessionId = fields.sessionId or "",
        metadata  = fields.metadata,
    }
end

--- Create an Attachment table.
-- @param fields table with keys: displayName, path, type, filePath, selection, text
-- @return table Attachment
function M.Attachment(fields)
    fields = fields or {}
    return {
        displayName = fields.displayName or "",
        path        = fields.path,
        type        = fields.type or "file",
        filePath    = fields.filePath,
        selection   = fields.selection,
        text        = fields.text,
    }
end

-- ---------------------------------------------------------------------------
-- Response format constants
-- ---------------------------------------------------------------------------

M.ResponseFormat = {
    TEXT        = "text",
    IMAGE       = "image",
    JSON_OBJECT = "json_object",
}

-- ---------------------------------------------------------------------------
-- Image generation helpers
-- ---------------------------------------------------------------------------

--- Create image options for image generation.
-- @param opts table with optional fields: size, quality, style
-- @return table image options
function M.image_options(opts)
    opts = opts or {}
    return {
        size    = opts.size,
        quality = opts.quality,
        style   = opts.style,
    }
end

--- Parse assistant image data from a response.
-- @param data table with format, base64, url, revisedPrompt, width, height
-- @return table parsed image data
function M.parse_assistant_image_data(data)
    return {
        format        = data.format,
        base64        = data.base64,
        url           = data.url,
        revisedPrompt = data.revisedPrompt,
        width         = data.width,
        height        = data.height,
    }
end

--- Parse a content block from a mixed response.
-- @param block table with type and content fields
-- @return table parsed content block
function M.parse_content_block(block)
    if block.type == "image" and block.image then
        block.image = M.parse_assistant_image_data(block.image)
    end
    return block
end

return M
