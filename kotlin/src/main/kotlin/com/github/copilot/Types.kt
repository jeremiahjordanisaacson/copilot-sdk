/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

package com.github.copilot

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// ============================================================================
// Connection State
// ============================================================================

/**
 * Connection state of the client.
 */
enum class ConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    ERROR
}

// ============================================================================
// Tool Types
// ============================================================================

/**
 * Result type from a tool execution.
 */
@Serializable
enum class ToolResultType {
    @SerialName("success") SUCCESS,
    @SerialName("failure") FAILURE,
    @SerialName("rejected") REJECTED,
    @SerialName("denied") DENIED
}

/**
 * Binary result from a tool execution.
 */
@Serializable
data class ToolBinaryResult(
    val data: String,
    val mimeType: String,
    val type: String,
    val description: String? = null
)

/**
 * Structured result from a tool execution.
 */
@Serializable
data class ToolResultObject(
    val textResultForLlm: String,
    val resultType: String,
    val binaryResultsForLlm: List<ToolBinaryResult>? = null,
    val error: String? = null,
    val sessionLog: String? = null,
    val toolTelemetry: Map<String, JsonElement>? = null
)

/**
 * Information about a tool invocation.
 */
data class ToolInvocation(
    val sessionId: String,
    val toolCallId: String,
    val toolName: String,
    val arguments: Any?
)

/**
 * Handler function for tool calls.
 */
typealias ToolHandler = suspend (args: Any?, invocation: ToolInvocation) -> Any?

/**
 * Tool definition for registering custom tools.
 */
data class Tool(
    val name: String,
    val description: String? = null,
    val parameters: Map<String, Any?>? = null,
    val handler: ToolHandler
)

// ============================================================================
// System Message Configuration
// ============================================================================

/**
 * System message configuration.
 *
 * Use [mode] = "append" (default) to append content after SDK-managed sections.
 * Use [mode] = "replace" to provide the entire system message.
 */
@Serializable
data class SystemMessageConfig(
    val mode: String? = null,
    val content: String? = null
)

// ============================================================================
// Session Configuration
// ============================================================================

/**
 * Reasoning effort levels for models that support it.
 */
@Serializable
enum class ReasoningEffort {
    @SerialName("low") LOW,
    @SerialName("medium") MEDIUM,
    @SerialName("high") HIGH,
    @SerialName("xhigh") XHIGH
}

/**
 * Configuration for a custom API provider (BYOK).
 */
@Serializable
data class ProviderConfig(
    val type: String? = null,
    val wireApi: String? = null,
    val baseUrl: String,
    val apiKey: String? = null,
    val bearerToken: String? = null,
    val azure: AzureConfig? = null
) {
    @Serializable
    data class AzureConfig(
        val apiVersion: String? = null
    )
}

/**
 * MCP server configuration.
 */
@Serializable
data class MCPServerConfig(
    val tools: List<String>,
    val type: String? = null,
    val timeout: Int? = null,
    val command: String? = null,
    val args: List<String>? = null,
    val env: Map<String, String>? = null,
    val cwd: String? = null,
    val url: String? = null,
    val headers: Map<String, String>? = null
)

/**
 * Custom agent configuration.
 */
@Serializable
data class CustomAgentConfig(
    val name: String,
    val displayName: String? = null,
    val description: String? = null,
    val tools: List<String>? = null,
    val prompt: String,
    val mcpServers: Map<String, MCPServerConfig>? = null,
    val infer: Boolean? = null
)

/**
 * Infinite session configuration.
 */
@Serializable
data class InfiniteSessionConfig(
    val enabled: Boolean? = null,
    val backgroundCompactionThreshold: Double? = null,
    val bufferExhaustionThreshold: Double? = null
)

/**
 * Configuration for creating a session.
 */
data class SessionConfig(
    val sessionId: String? = null,
    val model: String? = null,
    val reasoningEffort: ReasoningEffort? = null,
    val configDir: String? = null,
    val tools: List<Tool>? = null,
    val systemMessage: SystemMessageConfig? = null,
    val availableTools: List<String>? = null,
    val excludedTools: List<String>? = null,
    val provider: ProviderConfig? = null,
    val onPermissionRequest: PermissionHandler? = null,
    val onUserInputRequest: UserInputHandler? = null,
    val hooks: SessionHooks? = null,
    val workingDirectory: String? = null,
    val streaming: Boolean? = null,
    val mcpServers: Map<String, MCPServerConfig>? = null,
    val customAgents: List<CustomAgentConfig>? = null,
    val skillDirectories: List<String>? = null,
    val disabledSkills: List<String>? = null,
    val infiniteSessions: InfiniteSessionConfig? = null
)

/**
 * Configuration for resuming a session.
 */
data class ResumeSessionConfig(
    val model: String? = null,
    val reasoningEffort: ReasoningEffort? = null,
    val configDir: String? = null,
    val tools: List<Tool>? = null,
    val systemMessage: SystemMessageConfig? = null,
    val availableTools: List<String>? = null,
    val excludedTools: List<String>? = null,
    val provider: ProviderConfig? = null,
    val onPermissionRequest: PermissionHandler? = null,
    val onUserInputRequest: UserInputHandler? = null,
    val hooks: SessionHooks? = null,
    val workingDirectory: String? = null,
    val streaming: Boolean? = null,
    val mcpServers: Map<String, MCPServerConfig>? = null,
    val customAgents: List<CustomAgentConfig>? = null,
    val skillDirectories: List<String>? = null,
    val disabledSkills: List<String>? = null,
    val infiniteSessions: InfiniteSessionConfig? = null,
    val disableResume: Boolean? = null
)

// ============================================================================
// Session Event Types
// ============================================================================

/**
 * Session event from the server.
 */
@Serializable
data class SessionEvent(
    val type: String,
    val data: JsonObject? = null
)

/**
 * Event handler for session events.
 */
typealias SessionEventHandler = (event: SessionEvent) -> Unit

// ============================================================================
// Permission Types
// ============================================================================

/**
 * Permission request from the server.
 */
@Serializable
data class PermissionRequest(
    val kind: String,
    val toolCallId: String? = null
)

/**
 * Permission request result.
 */
@Serializable
data class PermissionRequestResult(
    val kind: String,
    val rules: List<JsonElement>? = null
)

/**
 * Handler for permission requests.
 */
typealias PermissionHandler = suspend (request: PermissionRequest, sessionId: String) -> PermissionRequestResult

// ============================================================================
// User Input Types
// ============================================================================

/**
 * Request for user input from the agent (enables ask_user tool).
 */
@Serializable
data class UserInputRequest(
    val question: String,
    val choices: List<String>? = null,
    val allowFreeform: Boolean? = null
)

/**
 * Response to a user input request.
 */
@Serializable
data class UserInputResponse(
    val answer: String,
    val wasFreeform: Boolean
)

/**
 * Handler for user input requests.
 */
typealias UserInputHandler = suspend (request: UserInputRequest, sessionId: String) -> UserInputResponse

// ============================================================================
// Hook Types
// ============================================================================

/**
 * Generic hook handler type.
 * Takes hook input (as a map) and a session ID, returns hook output (as a map) or null.
 */
typealias HookHandler = suspend (input: Map<String, Any?>, sessionId: String) -> Map<String, Any?>?

/**
 * Configuration for session hooks - lifecycle event interceptors.
 */
data class SessionHooks(
    val onPreToolUse: HookHandler? = null,
    val onPostToolUse: HookHandler? = null,
    val onUserPromptSubmitted: HookHandler? = null,
    val onSessionStart: HookHandler? = null,
    val onSessionEnd: HookHandler? = null,
    val onErrorOccurred: HookHandler? = null
) {
    /**
     * Returns true if any hook handler is registered.
     */
    fun hasAnyHook(): Boolean =
        onPreToolUse != null || onPostToolUse != null || onUserPromptSubmitted != null ||
            onSessionStart != null || onSessionEnd != null || onErrorOccurred != null

    /**
     * Gets a handler by hook type name.
     */
    fun getHandler(hookType: String): HookHandler? = when (hookType) {
        "preToolUse" -> onPreToolUse
        "postToolUse" -> onPostToolUse
        "userPromptSubmitted" -> onUserPromptSubmitted
        "sessionStart" -> onSessionStart
        "sessionEnd" -> onSessionEnd
        "errorOccurred" -> onErrorOccurred
        else -> null
    }
}

// ============================================================================
// Image Generation Types
// ============================================================================

/**
 * Response format for message responses.
 */
@Serializable
enum class ResponseFormat {
    @SerialName("text") TEXT,
    @SerialName("image") IMAGE,
    @SerialName("json_object") JSON_OBJECT
}

/**
 * Options for image generation.
 */
@Serializable
data class ImageOptions(
    val size: String? = null,
    val quality: String? = null,
    val style: String? = null
)

/**
 * Image data from an assistant image response.
 */
@Serializable
data class AssistantImageData(
    val format: String,
    val base64: String,
    val url: String? = null,
    val revisedPrompt: String? = null,
    val width: Int,
    val height: Int
)

/**
 * A content block in a mixed text+image response.
 */
@Serializable
data class ContentBlock(
    val type: String,
    val text: String? = null,
    val image: AssistantImageData? = null
)

// ============================================================================
// Message Options
// ============================================================================

/**
 * Attachment for a message.
 */
@Serializable
data class Attachment(
    val type: String,
    val path: String? = null,
    val filePath: String? = null,
    val displayName: String? = null,
    val selection: SelectionRange? = null,
    val text: String? = null
) {
    @Serializable
    data class SelectionRange(
        val start: Position,
        val end: Position
    )

    @Serializable
    data class Position(
        val line: Int,
        val character: Int
    )
}

/**
 * Options for sending a message to a session.
 */
data class MessageOptions(
    val prompt: String,
    val attachments: List<Attachment>? = null,
    val mode: String? = null,
    val responseFormat: ResponseFormat? = null,
    val imageOptions: ImageOptions? = null
)

// ============================================================================
// Ping / Status / Auth Types
// ============================================================================

/**
 * Response from a ping request.
 */
@Serializable
data class PingResponse(
    val message: String? = null,
    val timestamp: Long = 0,
    val protocolVersion: Int? = null
)

/**
 * Response from status.get.
 */
@Serializable
data class GetStatusResponse(
    val version: String,
    val protocolVersion: Int
)

/**
 * Response from auth.getStatus.
 */
@Serializable
data class GetAuthStatusResponse(
    val isAuthenticated: Boolean,
    val authType: String? = null,
    val host: String? = null,
    val login: String? = null,
    val statusMessage: String? = null
)

// ============================================================================
// Model Types
// ============================================================================

/**
 * Model supports flags.
 */
@Serializable
data class ModelSupports(
    val vision: Boolean = false,
    val reasoningEffort: Boolean = false
)

/**
 * Model limits.
 */
@Serializable
data class ModelLimits(
    @SerialName("max_prompt_tokens")
    val maxPromptTokens: Int? = null,
    @SerialName("max_context_window_tokens")
    val maxContextWindowTokens: Int = 0
)

/**
 * Model capabilities and limits.
 */
@Serializable
data class ModelCapabilities(
    val supports: ModelSupports = ModelSupports(),
    val limits: ModelLimits = ModelLimits()
)

/**
 * Model policy state.
 */
@Serializable
data class ModelPolicy(
    val state: String,
    val terms: String
)

/**
 * Model billing information.
 */
@Serializable
data class ModelBilling(
    val multiplier: Double
)

/**
 * Information about an available model.
 */
@Serializable
data class ModelInfo(
    val id: String,
    val name: String,
    val capabilities: ModelCapabilities = ModelCapabilities(),
    val policy: ModelPolicy? = null,
    val billing: ModelBilling? = null,
    val supportedReasoningEfforts: List<String>? = null,
    val defaultReasoningEffort: String? = null
)

// ============================================================================
// Session Metadata
// ============================================================================

/**
 * Metadata about a session.
 */
@Serializable
data class SessionMetadata(
    val sessionId: String,
    val startTime: String,
    val modifiedTime: String,
    val summary: String? = null,
    val isRemote: Boolean = false
)

// ============================================================================
// Session Lifecycle Types
// ============================================================================

/**
 * Session lifecycle event notification.
 */
@Serializable
data class SessionLifecycleEvent(
    val type: String,
    val sessionId: String,
    val metadata: LifecycleMetadata? = null
) {
    @Serializable
    data class LifecycleMetadata(
        val startTime: String? = null,
        val modifiedTime: String? = null,
        val summary: String? = null
    )
}

/**
 * Handler for session lifecycle events.
 */
typealias SessionLifecycleHandler = (event: SessionLifecycleEvent) -> Unit

// ============================================================================
// Client Options
// ============================================================================

/**
 * Options for creating a [CopilotClient].
 */
data class CopilotClientOptions(
    /**
     * Path to the CLI executable.
     * Defaults to "copilot" (found via PATH) or COPILOT_CLI_PATH env var.
     */
    val cliPath: String? = null,

    /**
     * Extra arguments to pass to the CLI executable (inserted before SDK-managed args).
     */
    val cliArgs: List<String>? = null,

    /**
     * Working directory for the CLI process.
     */
    val cwd: String? = null,

    /**
     * Port for the CLI server (TCP mode only). 0 = random available port.
     */
    val port: Int = 0,

    /**
     * Use stdio transport instead of TCP.
     * When true, communicates with CLI via stdin/stdout pipes.
     * Defaults to true.
     */
    val useStdio: Boolean? = null,

    /**
     * URL of an existing Copilot CLI server to connect to over TCP.
     * When provided, the client will not spawn a CLI process.
     * Mutually exclusive with cliPath, useStdio.
     */
    val cliUrl: String? = null,

    /**
     * Log level for the CLI server.
     */
    val logLevel: String = "info",

    /**
     * Auto-start the CLI server on first use. Defaults to true.
     */
    val autoStart: Boolean = true,

    /**
     * Auto-restart the CLI server if it crashes. Defaults to true.
     */
    val autoRestart: Boolean = true,

    /**
     * Environment variables to pass to the CLI process.
     */
    val env: Map<String, String>? = null,

    /**
     * GitHub token for authentication.
     */
    val githubToken: String? = null,

    /**
     * Whether to use the logged-in user for authentication. Defaults to true (false when githubToken provided).
     */
    val useLoggedInUser: Boolean? = null
)
