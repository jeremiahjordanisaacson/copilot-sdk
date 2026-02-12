// Copyright (c) Microsoft Corporation. All rights reserved.

package com.github.copilot

import io.circe.*
import io.circe.generic.semiauto.*
import io.circe.syntax.*
import scala.concurrent.Future

// ============================================================================
// Connection State
// ============================================================================

/** Connection state of the client. */
enum ConnectionState:
  case Disconnected, Connecting, Connected, Error

// ============================================================================
// Tool Types
// ============================================================================

/** Result type for tool invocations. */
enum ToolResultType(val value: String):
  case Success  extends ToolResultType("success")
  case Failure  extends ToolResultType("failure")
  case Rejected extends ToolResultType("rejected")
  case Denied   extends ToolResultType("denied")

object ToolResultType:
  given Encoder[ToolResultType] = Encoder.encodeString.contramap(_.value)
  given Decoder[ToolResultType] = Decoder.decodeString.emap:
    case "success"  => Right(ToolResultType.Success)
    case "failure"  => Right(ToolResultType.Failure)
    case "rejected" => Right(ToolResultType.Rejected)
    case "denied"   => Right(ToolResultType.Denied)
    case other      => Left(s"Unknown ToolResultType: $other")

/** Binary result payload from a tool invocation. */
case class ToolBinaryResult(
  data: String,
  mimeType: String,
  `type`: String,
  description: Option[String] = None
)

object ToolBinaryResult:
  given Encoder[ToolBinaryResult] = deriveEncoder
  given Decoder[ToolBinaryResult] = deriveDecoder

/** Structured result object returned by a tool handler. */
case class ToolResultObject(
  textResultForLlm: String,
  resultType: ToolResultType,
  binaryResultsForLlm: Option[List[ToolBinaryResult]] = None,
  error: Option[String] = None,
  sessionLog: Option[String] = None,
  toolTelemetry: Option[Map[String, Json]] = None
)

object ToolResultObject:
  given Encoder[ToolResultObject] = deriveEncoder
  given Decoder[ToolResultObject] = deriveDecoder

/** Tool invocation context passed to tool handlers. */
case class ToolInvocation(
  sessionId: String,
  toolCallId: String,
  toolName: String,
  arguments: Json
)

object ToolInvocation:
  given Encoder[ToolInvocation] = deriveEncoder
  given Decoder[ToolInvocation] = deriveDecoder

/**
 * Tool handler function type.
 * Receives the parsed arguments as Json and the invocation context.
 * Returns a Future of either a ToolResultObject or any value (which will be wrapped).
 */
type ToolHandler = (Json, ToolInvocation) => Future[ToolResultObject]

/**
 * A tool definition exposed to the Copilot CLI.
 *
 * @param name        Unique name of the tool
 * @param description Human-readable description
 * @param parameters  JSON Schema describing the tool's parameters
 * @param handler     Function invoked when the CLI calls this tool
 */
case class Tool(
  name: String,
  description: Option[String] = None,
  parameters: Option[JsonObject] = None,
  handler: ToolHandler
)

// ============================================================================
// Session Configuration
// ============================================================================

/** System message configuration -- append mode (default). */
case class SystemMessageAppendConfig(
  mode: Option[String] = Some("append"),
  content: Option[String] = None
)

object SystemMessageAppendConfig:
  given Encoder[SystemMessageAppendConfig] = deriveEncoder
  given Decoder[SystemMessageAppendConfig] = deriveDecoder

/** System message configuration -- replace mode. */
case class SystemMessageReplaceConfig(
  mode: String = "replace",
  content: String
)

object SystemMessageReplaceConfig:
  given Encoder[SystemMessageReplaceConfig] = deriveEncoder
  given Decoder[SystemMessageReplaceConfig] = deriveDecoder

/** Unified system message config sent over the wire. */
case class SystemMessageConfig(
  mode: Option[String] = None,
  content: Option[String] = None
)

object SystemMessageConfig:
  given Encoder[SystemMessageConfig] = deriveEncoder
  given Decoder[SystemMessageConfig] = deriveDecoder

  def append(content: String): SystemMessageConfig =
    SystemMessageConfig(mode = Some("append"), content = Some(content))

  def replace(content: String): SystemMessageConfig =
    SystemMessageConfig(mode = Some("replace"), content = Some(content))

// ============================================================================
// Provider Configuration
// ============================================================================

/** Azure-specific provider options. */
case class AzureProviderOptions(
  apiVersion: Option[String] = None
)

object AzureProviderOptions:
  given Encoder[AzureProviderOptions] = deriveEncoder
  given Decoder[AzureProviderOptions] = deriveDecoder

/** Custom model provider configuration (BYOK). */
case class ProviderConfig(
  baseUrl: String,
  `type`: Option[String] = None,
  wireApi: Option[String] = None,
  apiKey: Option[String] = None,
  bearerToken: Option[String] = None,
  azure: Option[AzureProviderOptions] = None
)

object ProviderConfig:
  given Encoder[ProviderConfig] = deriveEncoder
  given Decoder[ProviderConfig] = deriveDecoder

// ============================================================================
// MCP Server Configuration
// ============================================================================

/** MCP server configuration, sent as a JSON object. */
type MCPServerConfig = JsonObject

/** Helper to build a local/stdio MCP server config. */
object MCPServerConfig:
  def local(
    command: String,
    args: List[String],
    tools: List[String] = List("*"),
    `type`: Option[String] = None,
    env: Option[Map[String, String]] = None,
    cwd: Option[String] = None,
    timeout: Option[Int] = None
  ): JsonObject =
    JsonObject(
      "command" -> command.asJson,
      "args" -> args.asJson,
      "tools" -> tools.asJson,
      "type" -> `type`.getOrElse("local").asJson,
      "env" -> env.asJson,
      "cwd" -> cwd.asJson,
      "timeout" -> timeout.asJson,
    ).filter { case (_, v) => !v.isNull }

  def remote(
    url: String,
    `type`: String = "http",
    tools: List[String] = List("*"),
    headers: Option[Map[String, String]] = None,
    timeout: Option[Int] = None
  ): JsonObject =
    JsonObject(
      "url" -> url.asJson,
      "type" -> `type`.asJson,
      "tools" -> tools.asJson,
      "headers" -> headers.asJson,
      "timeout" -> timeout.asJson,
    ).filter { case (_, v) => !v.isNull }

// ============================================================================
// Custom Agent Configuration
// ============================================================================

/** Configuration for a custom agent. */
case class CustomAgentConfig(
  name: String,
  prompt: String,
  displayName: Option[String] = None,
  description: Option[String] = None,
  tools: Option[List[String]] = None,
  mcpServers: Option[Map[String, JsonObject]] = None,
  infer: Option[Boolean] = None
)

object CustomAgentConfig:
  given Encoder[CustomAgentConfig] = deriveEncoder
  given Decoder[CustomAgentConfig] = deriveDecoder

// ============================================================================
// Infinite Session Configuration
// ============================================================================

/** Configuration for infinite sessions with automatic context compaction. */
case class InfiniteSessionConfig(
  enabled: Option[Boolean] = None,
  backgroundCompactionThreshold: Option[Double] = None,
  bufferExhaustionThreshold: Option[Double] = None
)

object InfiniteSessionConfig:
  given Encoder[InfiniteSessionConfig] = deriveEncoder
  given Decoder[InfiniteSessionConfig] = deriveDecoder

// ============================================================================
// Session Configuration
// ============================================================================

/** Valid reasoning effort levels. */
enum ReasoningEffort(val value: String):
  case Low    extends ReasoningEffort("low")
  case Medium extends ReasoningEffort("medium")
  case High   extends ReasoningEffort("high")
  case XHigh  extends ReasoningEffort("xhigh")

object ReasoningEffort:
  given Encoder[ReasoningEffort] = Encoder.encodeString.contramap(_.value)
  given Decoder[ReasoningEffort] = Decoder.decodeString.emap:
    case "low"    => Right(ReasoningEffort.Low)
    case "medium" => Right(ReasoningEffort.Medium)
    case "high"   => Right(ReasoningEffort.High)
    case "xhigh"  => Right(ReasoningEffort.XHigh)
    case other    => Left(s"Unknown ReasoningEffort: $other")

/** Configuration for creating a new session. */
case class SessionConfig(
  sessionId: Option[String] = None,
  model: Option[String] = None,
  reasoningEffort: Option[ReasoningEffort] = None,
  configDir: Option[String] = None,
  tools: List[Tool] = Nil,
  systemMessage: Option[SystemMessageConfig] = None,
  availableTools: Option[List[String]] = None,
  excludedTools: Option[List[String]] = None,
  provider: Option[ProviderConfig] = None,
  onPermissionRequest: Option[PermissionHandler] = None,
  onUserInputRequest: Option[UserInputHandler] = None,
  hooks: Option[SessionHooks] = None,
  workingDirectory: Option[String] = None,
  streaming: Option[Boolean] = None,
  mcpServers: Option[Map[String, JsonObject]] = None,
  customAgents: Option[List[CustomAgentConfig]] = None,
  skillDirectories: Option[List[String]] = None,
  disabledSkills: Option[List[String]] = None,
  infiniteSessions: Option[InfiniteSessionConfig] = None
)

/** Configuration for resuming an existing session. */
case class ResumeSessionConfig(
  model: Option[String] = None,
  reasoningEffort: Option[ReasoningEffort] = None,
  configDir: Option[String] = None,
  tools: List[Tool] = Nil,
  systemMessage: Option[SystemMessageConfig] = None,
  availableTools: Option[List[String]] = None,
  excludedTools: Option[List[String]] = None,
  provider: Option[ProviderConfig] = None,
  onPermissionRequest: Option[PermissionHandler] = None,
  onUserInputRequest: Option[UserInputHandler] = None,
  hooks: Option[SessionHooks] = None,
  workingDirectory: Option[String] = None,
  streaming: Option[Boolean] = None,
  mcpServers: Option[Map[String, JsonObject]] = None,
  customAgents: Option[List[CustomAgentConfig]] = None,
  skillDirectories: Option[List[String]] = None,
  disabledSkills: Option[List[String]] = None,
  infiniteSessions: Option[InfiniteSessionConfig] = None,
  disableResume: Option[Boolean] = None
)

// ============================================================================
// Session Events
// ============================================================================

/**
 * A session event from the Copilot CLI.
 * Events are represented as a typed wrapper around the raw JSON, giving access
 * to the event type discriminator and the full payload.
 */
case class SessionEvent(
  `type`: String,
  id: String,
  parentId: Option[String],
  timestamp: String,
  ephemeral: Option[Boolean] = None,
  data: Json = Json.obj()
)

object SessionEvent:
  given Decoder[SessionEvent] = Decoder.instance { c =>
    for
      tpe       <- c.get[String]("type")
      id        <- c.get[String]("id")
      parentId  <- c.get[Option[String]]("parentId")
      timestamp <- c.get[String]("timestamp")
      ephemeral <- c.get[Option[Boolean]]("ephemeral")
      data      <- c.get[Json]("data")
    yield SessionEvent(tpe, id, parentId, timestamp, ephemeral, data)
  }

  given Encoder[SessionEvent] = Encoder.instance { e =>
    Json.obj(
      "type" -> e.`type`.asJson,
      "id" -> e.id.asJson,
      "parentId" -> e.parentId.asJson,
      "timestamp" -> e.timestamp.asJson,
      "ephemeral" -> e.ephemeral.asJson,
      "data" -> e.data
    )
  }

/** All known session event type strings. */
object SessionEventType:
  val Abort                       = "abort"
  val AssistantIntent             = "assistant.intent"
  val AssistantMessage            = "assistant.message"
  val AssistantMessageDelta       = "assistant.message_delta"
  val AssistantReasoning          = "assistant.reasoning"
  val AssistantReasoningDelta     = "assistant.reasoning_delta"
  val AssistantTurnEnd            = "assistant.turn_end"
  val AssistantTurnStart          = "assistant.turn_start"
  val AssistantUsage              = "assistant.usage"
  val HookEnd                     = "hook.end"
  val HookStart                   = "hook.start"
  val PendingMessagesModified     = "pending_messages.modified"
  val SessionCompactionComplete   = "session.compaction_complete"
  val SessionCompactionStart      = "session.compaction_start"
  val SessionError                = "session.error"
  val SessionHandoff              = "session.handoff"
  val SessionIdle                 = "session.idle"
  val SessionInfo                 = "session.info"
  val SessionModelChange          = "session.model_change"
  val SessionResume               = "session.resume"
  val SessionShutdown             = "session.shutdown"
  val SessionSnapshotRewind       = "session.snapshot_rewind"
  val SessionStart                = "session.start"
  val SessionTruncation           = "session.truncation"
  val SessionUsageInfo            = "session.usage_info"
  val SkillInvoked                = "skill.invoked"
  val SubagentCompleted           = "subagent.completed"
  val SubagentFailed              = "subagent.failed"
  val SubagentSelected            = "subagent.selected"
  val SubagentStarted             = "subagent.started"
  val SystemMessage               = "system.message"
  val ToolExecutionComplete       = "tool.execution_complete"
  val ToolExecutionPartialResult  = "tool.execution_partial_result"
  val ToolExecutionProgress       = "tool.execution_progress"
  val ToolExecutionStart          = "tool.execution_start"
  val ToolUserRequested           = "tool.user_requested"
  val UserMessage                 = "user.message"

// ============================================================================
// Permission Types
// ============================================================================

/** Permission request from the server. */
case class PermissionRequest(
  kind: String,
  toolCallId: Option[String] = None,
  extra: Json = Json.obj()
)

object PermissionRequest:
  given Decoder[PermissionRequest] = Decoder.instance { c =>
    for
      kind       <- c.get[String]("kind")
      toolCallId <- c.get[Option[String]]("toolCallId")
    yield PermissionRequest(kind, toolCallId, c.value)
  }

/** Result of a permission request. */
case class PermissionRequestResult(
  kind: String,
  rules: Option[List[Json]] = None
)

object PermissionRequestResult:
  given Encoder[PermissionRequestResult] = deriveEncoder
  given Decoder[PermissionRequestResult] = deriveDecoder

  val Approved = "approved"
  val DeniedByRules = "denied-by-rules"
  val DeniedNoApprovalRule = "denied-no-approval-rule-and-could-not-request-from-user"
  val DeniedInteractively = "denied-interactively-by-user"

/** Permission handler function type. */
type PermissionHandler = (PermissionRequest, PermissionInvocation) => Future[PermissionRequestResult]

/** Context for a permission request invocation. */
case class PermissionInvocation(sessionId: String)

// ============================================================================
// User Input Types
// ============================================================================

/** Request for user input from the agent (enables ask_user tool). */
case class UserInputRequest(
  question: String,
  choices: Option[List[String]] = None,
  allowFreeform: Option[Boolean] = None
)

object UserInputRequest:
  given Encoder[UserInputRequest] = deriveEncoder
  given Decoder[UserInputRequest] = deriveDecoder

/** Response to a user input request. */
case class UserInputResponse(
  answer: String,
  wasFreeform: Boolean
)

object UserInputResponse:
  given Encoder[UserInputResponse] = deriveEncoder
  given Decoder[UserInputResponse] = deriveDecoder

/** User input handler function type. */
type UserInputHandler = (UserInputRequest, UserInputInvocation) => Future[UserInputResponse]

/** Context for a user input invocation. */
case class UserInputInvocation(sessionId: String)

// ============================================================================
// Hook Types
// ============================================================================

/** Context for hook invocations. */
case class HookInvocation(sessionId: String)

/** Input for pre-tool-use hook. */
case class PreToolUseHookInput(
  timestamp: Long,
  cwd: String,
  toolName: String,
  toolArgs: Json
)

object PreToolUseHookInput:
  given Decoder[PreToolUseHookInput] = deriveDecoder

/** Output for pre-tool-use hook. */
case class PreToolUseHookOutput(
  permissionDecision: Option[String] = None,
  permissionDecisionReason: Option[String] = None,
  modifiedArgs: Option[Json] = None,
  additionalContext: Option[String] = None,
  suppressOutput: Option[Boolean] = None
)

object PreToolUseHookOutput:
  given Encoder[PreToolUseHookOutput] = deriveEncoder

type PreToolUseHandler = (PreToolUseHookInput, HookInvocation) => Future[Option[PreToolUseHookOutput]]

/** Input for post-tool-use hook. */
case class PostToolUseHookInput(
  timestamp: Long,
  cwd: String,
  toolName: String,
  toolArgs: Json,
  toolResult: Json
)

object PostToolUseHookInput:
  given Decoder[PostToolUseHookInput] = deriveDecoder

/** Output for post-tool-use hook. */
case class PostToolUseHookOutput(
  modifiedResult: Option[Json] = None,
  additionalContext: Option[String] = None,
  suppressOutput: Option[Boolean] = None
)

object PostToolUseHookOutput:
  given Encoder[PostToolUseHookOutput] = deriveEncoder

type PostToolUseHandler = (PostToolUseHookInput, HookInvocation) => Future[Option[PostToolUseHookOutput]]

/** Input for user-prompt-submitted hook. */
case class UserPromptSubmittedHookInput(
  timestamp: Long,
  cwd: String,
  prompt: String
)

object UserPromptSubmittedHookInput:
  given Decoder[UserPromptSubmittedHookInput] = deriveDecoder

/** Output for user-prompt-submitted hook. */
case class UserPromptSubmittedHookOutput(
  modifiedPrompt: Option[String] = None,
  additionalContext: Option[String] = None,
  suppressOutput: Option[Boolean] = None
)

object UserPromptSubmittedHookOutput:
  given Encoder[UserPromptSubmittedHookOutput] = deriveEncoder

type UserPromptSubmittedHandler = (UserPromptSubmittedHookInput, HookInvocation) => Future[Option[UserPromptSubmittedHookOutput]]

/** Input for session-start hook. */
case class SessionStartHookInput(
  timestamp: Long,
  cwd: String,
  source: String,
  initialPrompt: Option[String] = None
)

object SessionStartHookInput:
  given Decoder[SessionStartHookInput] = deriveDecoder

/** Output for session-start hook. */
case class SessionStartHookOutput(
  additionalContext: Option[String] = None,
  modifiedConfig: Option[Map[String, Json]] = None
)

object SessionStartHookOutput:
  given Encoder[SessionStartHookOutput] = deriveEncoder

type SessionStartHandler = (SessionStartHookInput, HookInvocation) => Future[Option[SessionStartHookOutput]]

/** Input for session-end hook. */
case class SessionEndHookInput(
  timestamp: Long,
  cwd: String,
  reason: String,
  finalMessage: Option[String] = None,
  error: Option[String] = None
)

object SessionEndHookInput:
  given Decoder[SessionEndHookInput] = deriveDecoder

/** Output for session-end hook. */
case class SessionEndHookOutput(
  suppressOutput: Option[Boolean] = None,
  cleanupActions: Option[List[String]] = None,
  sessionSummary: Option[String] = None
)

object SessionEndHookOutput:
  given Encoder[SessionEndHookOutput] = deriveEncoder

type SessionEndHandler = (SessionEndHookInput, HookInvocation) => Future[Option[SessionEndHookOutput]]

/** Input for error-occurred hook. */
case class ErrorOccurredHookInput(
  timestamp: Long,
  cwd: String,
  error: String,
  errorContext: String,
  recoverable: Boolean
)

object ErrorOccurredHookInput:
  given Decoder[ErrorOccurredHookInput] = deriveDecoder

/** Output for error-occurred hook. */
case class ErrorOccurredHookOutput(
  suppressOutput: Option[Boolean] = None,
  errorHandling: Option[String] = None,
  retryCount: Option[Int] = None,
  userNotification: Option[String] = None
)

object ErrorOccurredHookOutput:
  given Encoder[ErrorOccurredHookOutput] = deriveEncoder

type ErrorOccurredHandler = (ErrorOccurredHookInput, HookInvocation) => Future[Option[ErrorOccurredHookOutput]]

/** Configuration for session hooks. */
case class SessionHooks(
  onPreToolUse: Option[PreToolUseHandler] = None,
  onPostToolUse: Option[PostToolUseHandler] = None,
  onUserPromptSubmitted: Option[UserPromptSubmittedHandler] = None,
  onSessionStart: Option[SessionStartHandler] = None,
  onSessionEnd: Option[SessionEndHandler] = None,
  onErrorOccurred: Option[ErrorOccurredHandler] = None
):
  /** Returns true if at least one hook handler is registered. */
  def hasAny: Boolean =
    onPreToolUse.isDefined || onPostToolUse.isDefined ||
      onUserPromptSubmitted.isDefined || onSessionStart.isDefined ||
      onSessionEnd.isDefined || onErrorOccurred.isDefined

// ============================================================================
// Ping Response
// ============================================================================

/** Response from a ping request. */
case class PingResponse(
  message: String,
  timestamp: Long,
  protocolVersion: Option[Int] = None
)

object PingResponse:
  given Decoder[PingResponse] = deriveDecoder

// ============================================================================
// Status Responses
// ============================================================================

/** Response from status.get. */
case class GetStatusResponse(
  version: String,
  protocolVersion: Int
)

object GetStatusResponse:
  given Decoder[GetStatusResponse] = deriveDecoder

/** Response from auth.getStatus. */
case class GetAuthStatusResponse(
  isAuthenticated: Boolean,
  authType: Option[String] = None,
  host: Option[String] = None,
  login: Option[String] = None,
  statusMessage: Option[String] = None
)

object GetAuthStatusResponse:
  given Decoder[GetAuthStatusResponse] = deriveDecoder

// ============================================================================
// Model Information
// ============================================================================

/** Model support flags. */
case class ModelSupports(
  vision: Boolean,
  reasoningEffort: Boolean
)

object ModelSupports:
  given Decoder[ModelSupports] = deriveDecoder

/** Model vision limits. */
case class ModelVisionLimits(
  supported_media_types: List[String],
  max_prompt_images: Int,
  max_prompt_image_size: Int
)

object ModelVisionLimits:
  given Decoder[ModelVisionLimits] = deriveDecoder

/** Model limits. */
case class ModelLimits(
  max_context_window_tokens: Int,
  max_prompt_tokens: Option[Int] = None,
  vision: Option[ModelVisionLimits] = None
)

object ModelLimits:
  given Decoder[ModelLimits] = deriveDecoder

/** Model capabilities and limits. */
case class ModelCapabilities(
  supports: ModelSupports,
  limits: ModelLimits
)

object ModelCapabilities:
  given Decoder[ModelCapabilities] = deriveDecoder

/** Model policy state. */
case class ModelPolicy(
  state: String,
  terms: String
)

object ModelPolicy:
  given Decoder[ModelPolicy] = deriveDecoder

/** Model billing information. */
case class ModelBilling(
  multiplier: Double
)

object ModelBilling:
  given Decoder[ModelBilling] = deriveDecoder

/** Information about an available model. */
case class ModelInfo(
  id: String,
  name: String,
  capabilities: ModelCapabilities,
  policy: Option[ModelPolicy] = None,
  billing: Option[ModelBilling] = None,
  supportedReasoningEfforts: Option[List[String]] = None,
  defaultReasoningEffort: Option[String] = None
)

object ModelInfo:
  given Decoder[ModelInfo] = deriveDecoder

// ============================================================================
// Session Metadata
// ============================================================================

/** Metadata about a session. */
case class SessionMetadata(
  sessionId: String,
  startTime: String,
  modifiedTime: String,
  summary: Option[String] = None,
  isRemote: Boolean = false
)

object SessionMetadata:
  given Decoder[SessionMetadata] = deriveDecoder

// ============================================================================
// Session Lifecycle Events
// ============================================================================

/** Types of session lifecycle events. */
object SessionLifecycleEventType:
  val Created    = "session.created"
  val Deleted    = "session.deleted"
  val Updated    = "session.updated"
  val Foreground = "session.foreground"
  val Background = "session.background"

/** Metadata attached to lifecycle events. */
case class SessionLifecycleEventMetadata(
  startTime: String,
  modifiedTime: String,
  summary: Option[String] = None
)

object SessionLifecycleEventMetadata:
  given Decoder[SessionLifecycleEventMetadata] = deriveDecoder

/** Session lifecycle event notification. */
case class SessionLifecycleEvent(
  `type`: String,
  sessionId: String,
  metadata: Option[SessionLifecycleEventMetadata] = None
)

object SessionLifecycleEvent:
  given Decoder[SessionLifecycleEvent] = deriveDecoder

/** Handler for session lifecycle events. */
type SessionLifecycleHandler = SessionLifecycleEvent => Unit

// ============================================================================
// Response Format & Image Types
// ============================================================================

/** Response format for message responses. */
object ResponseFormat:
  val Text: String = "text"
  val Image: String = "image"
  val JsonObject: String = "json_object"

/** Options for image generation. */
case class ImageOptions(
  size: Option[String] = None,
  quality: Option[String] = None,
  style: Option[String] = None
)

object ImageOptions:
  given Encoder[ImageOptions] = deriveEncoder
  given Decoder[ImageOptions] = deriveDecoder

/** Image data from an assistant image response. */
case class AssistantImageData(
  format: String,
  base64: String,
  url: Option[String] = None,
  revisedPrompt: Option[String] = None,
  width: Int,
  height: Int
)

object AssistantImageData:
  given Encoder[AssistantImageData] = deriveEncoder
  given Decoder[AssistantImageData] = deriveDecoder

/** A content block in a mixed text+image response. */
sealed trait ContentBlock

case class TextBlock(text: String) extends ContentBlock

object TextBlock:
  given Encoder[TextBlock] = deriveEncoder
  given Decoder[TextBlock] = deriveDecoder

case class ImageBlock(image: AssistantImageData) extends ContentBlock

object ImageBlock:
  given Encoder[ImageBlock] = deriveEncoder
  given Decoder[ImageBlock] = deriveDecoder

object ContentBlock:
  given Encoder[ContentBlock] = Encoder.instance:
    case tb: TextBlock  => tb.asJson(using TextBlock.given_Encoder_TextBlock).deepMerge(Json.obj("type" -> "text".asJson))
    case ib: ImageBlock => ib.asJson(using ImageBlock.given_Encoder_ImageBlock).deepMerge(Json.obj("type" -> "image".asJson))

  given Decoder[ContentBlock] = Decoder.instance { c =>
    c.get[String]("type").flatMap:
      case "text"  => c.as[TextBlock]
      case "image" => c.as[ImageBlock]
      case other   => Left(DecodingFailure(s"Unknown content block type: $other", c.history))
  }

// ============================================================================
// Message Options
// ============================================================================

/** File attachment. */
case class FileAttachment(path: String, displayName: Option[String] = None)

/** Directory attachment. */
case class DirectoryAttachment(path: String, displayName: Option[String] = None)

/** Selection position. */
case class SelectionPosition(line: Int, character: Int)

object SelectionPosition:
  given Encoder[SelectionPosition] = deriveEncoder

/** Selection range. */
case class SelectionRange(start: SelectionPosition, end: SelectionPosition)

object SelectionRange:
  given Encoder[SelectionRange] = deriveEncoder

/** Selection attachment. */
case class SelectionAttachment(
  filePath: String,
  displayName: String,
  selection: Option[SelectionRange] = None,
  text: Option[String] = None
)

/** A message attachment -- one of file, directory, or selection. */
enum Attachment:
  case File(path: String, displayName: Option[String] = None)
  case Directory(path: String, displayName: Option[String] = None)
  case Selection(
    filePath: String,
    displayName: String,
    selection: Option[SelectionRange] = None,
    text: Option[String] = None
  )

object Attachment:
  given Encoder[Attachment] = Encoder.instance:
    case Attachment.File(path, dn) =>
      Json.obj(
        "type" -> "file".asJson,
        "path" -> path.asJson,
        "displayName" -> dn.asJson
      )
    case Attachment.Directory(path, dn) =>
      Json.obj(
        "type" -> "directory".asJson,
        "path" -> path.asJson,
        "displayName" -> dn.asJson
      )
    case Attachment.Selection(fp, dn, sel, txt) =>
      Json.obj(
        "type" -> "selection".asJson,
        "filePath" -> fp.asJson,
        "displayName" -> dn.asJson,
        "selection" -> sel.asJson,
        "text" -> txt.asJson
      )

  given Decoder[Attachment] = Decoder.instance { c =>
    c.get[String]("type").flatMap:
      case "file" =>
        for
          path <- c.get[String]("path")
          dn   <- c.get[Option[String]]("displayName")
        yield Attachment.File(path, dn)
      case "directory" =>
        for
          path <- c.get[String]("path")
          dn   <- c.get[Option[String]]("displayName")
        yield Attachment.Directory(path, dn)
      case "selection" =>
        for
          fp  <- c.get[String]("filePath")
          dn  <- c.get[String]("displayName")
          sel <- c.get[Option[SelectionRange]]("selection")
          txt <- c.get[Option[String]]("text")
        yield Attachment.Selection(fp, dn, sel, txt)
      case other =>
        Left(DecodingFailure(s"Unknown attachment type: $other", c.history))
  }

/** Options for sending a message to a session. */
case class MessageOptions(
  prompt: String,
  attachments: Option[List[Attachment]] = None,
  mode: Option[String] = None,
  responseFormat: Option[String] = None,
  imageOptions: Option[ImageOptions] = None
)

// ============================================================================
// Client Options
// ============================================================================

/**
 * Options for creating a CopilotClient.
 *
 * @param cliPath          Path to the Copilot CLI executable
 * @param cliArgs          Extra arguments to pass to the CLI before SDK-managed args
 * @param cwd              Working directory for the CLI process
 * @param port             Port for TCP transport (0 = random)
 * @param useStdio         Use stdio transport instead of TCP (default: true)
 * @param cliUrl           URL of an existing CLI server (mutually exclusive with cliPath/useStdio)
 * @param logLevel         Log level for the CLI server
 * @param autoStart        Auto-start on first use (default: true)
 * @param autoRestart      Auto-restart on crash (default: true)
 * @param env              Environment variables for the CLI process
 * @param githubToken      GitHub token for authentication
 * @param useLoggedInUser  Whether to use logged-in user authentication
 */
case class CopilotClientOptions(
  cliPath: Option[String] = None,
  cliArgs: List[String] = Nil,
  cwd: Option[String] = None,
  port: Int = 0,
  useStdio: Boolean = true,
  cliUrl: Option[String] = None,
  logLevel: String = "info",
  autoStart: Boolean = true,
  autoRestart: Boolean = true,
  env: Option[Map[String, String]] = None,
  githubToken: Option[String] = None,
  useLoggedInUser: Option[Boolean] = None
)
