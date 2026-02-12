// Copyright (c) Microsoft Corporation. All rights reserved.

/// Type definitions for the Copilot Dart SDK.
///
/// These types mirror the TypeScript SDK types and represent the JSON-RPC
/// protocol messages exchanged with the Copilot CLI server.

// ---------------------------------------------------------------------------
// Connection State
// ---------------------------------------------------------------------------

/// Connection state of the client to the CLI server.
enum ConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

// ---------------------------------------------------------------------------
// Tool Result Types
// ---------------------------------------------------------------------------

/// Result type for tool execution.
enum ToolResultType {
  success,
  failure,
  rejected,
  denied,
}

/// Extension to convert [ToolResultType] to/from JSON string.
extension ToolResultTypeJson on ToolResultType {
  String toJson() => name;

  static ToolResultType fromJson(String value) {
    return ToolResultType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ToolResultType.failure,
    );
  }
}

/// Binary result attached to a tool result.
class ToolBinaryResult {
  final String data;
  final String mimeType;
  final String type;
  final String? description;

  const ToolBinaryResult({
    required this.data,
    required this.mimeType,
    required this.type,
    this.description,
  });

  Map<String, dynamic> toJson() => {
        'data': data,
        'mimeType': mimeType,
        'type': type,
        if (description != null) 'description': description,
      };

  factory ToolBinaryResult.fromJson(Map<String, dynamic> json) {
    return ToolBinaryResult(
      data: json['data'] as String,
      mimeType: json['mimeType'] as String,
      type: json['type'] as String,
      description: json['description'] as String?,
    );
  }
}

/// Structured result returned from a tool handler.
class ToolResultObject {
  final String textResultForLlm;
  final List<ToolBinaryResult>? binaryResultsForLlm;
  final ToolResultType resultType;
  final String? error;
  final String? sessionLog;
  final Map<String, dynamic>? toolTelemetry;

  const ToolResultObject({
    required this.textResultForLlm,
    required this.resultType,
    this.binaryResultsForLlm,
    this.error,
    this.sessionLog,
    this.toolTelemetry,
  });

  Map<String, dynamic> toJson() => {
        'textResultForLlm': textResultForLlm,
        'resultType': resultType.toJson(),
        if (binaryResultsForLlm != null)
          'binaryResultsForLlm':
              binaryResultsForLlm!.map((b) => b.toJson()).toList(),
        if (error != null) 'error': error,
        if (sessionLog != null) 'sessionLog': sessionLog,
        if (toolTelemetry != null) 'toolTelemetry': toolTelemetry,
      };

  factory ToolResultObject.fromJson(Map<String, dynamic> json) {
    return ToolResultObject(
      textResultForLlm: json['textResultForLlm'] as String,
      resultType: ToolResultTypeJson.fromJson(json['resultType'] as String),
      binaryResultsForLlm: (json['binaryResultsForLlm'] as List<dynamic>?)
          ?.map((b) => ToolBinaryResult.fromJson(b as Map<String, dynamic>))
          .toList(),
      error: json['error'] as String?,
      sessionLog: json['sessionLog'] as String?,
      toolTelemetry: json['toolTelemetry'] as Map<String, dynamic>?,
    );
  }

  /// Returns true if [value] is shaped like a [ToolResultObject].
  static bool isToolResultObject(dynamic value) {
    return value is Map<String, dynamic> &&
        value.containsKey('textResultForLlm') &&
        value['textResultForLlm'] is String &&
        value.containsKey('resultType');
  }
}

// ---------------------------------------------------------------------------
// Tool Invocation
// ---------------------------------------------------------------------------

/// Context passed to a tool handler when a tool is called.
class ToolInvocation {
  final String sessionId;
  final String toolCallId;
  final String toolName;
  final dynamic arguments;

  const ToolInvocation({
    required this.sessionId,
    required this.toolCallId,
    required this.toolName,
    this.arguments,
  });
}

/// Handler function signature for tool calls.
///
/// Receives the parsed arguments and the [ToolInvocation] context.
/// Returns a value that will be sent back to the CLI server.
typedef ToolHandler = Future<dynamic> Function(
  dynamic args,
  ToolInvocation invocation,
);

// ---------------------------------------------------------------------------
// Tool Definition
// ---------------------------------------------------------------------------

/// A tool definition that can be registered with a session.
class Tool {
  /// Unique name of the tool.
  final String name;

  /// Human-readable description of the tool.
  final String? description;

  /// JSON Schema describing the tool parameters.
  final Map<String, dynamic>? parameters;

  /// Handler function invoked when the tool is called.
  final ToolHandler handler;

  const Tool({
    required this.name,
    this.description,
    this.parameters,
    required this.handler,
  });

  /// Serialize the tool definition for the JSON-RPC session.create call.
  Map<String, dynamic> toJson() => {
        'name': name,
        if (description != null) 'description': description,
        if (parameters != null) 'parameters': parameters,
      };
}

// ---------------------------------------------------------------------------
// System Message Configuration
// ---------------------------------------------------------------------------

/// System message in append mode (default).
/// Uses the CLI foundation with optional appended content.
class SystemMessageAppendConfig {
  final String? content;

  const SystemMessageAppendConfig({this.content});

  Map<String, dynamic> toJson() => {
        'mode': 'append',
        if (content != null) 'content': content,
      };
}

/// System message in replace mode.
/// Replaces the entire SDK-managed system message.
class SystemMessageReplaceConfig {
  final String content;

  const SystemMessageReplaceConfig({required this.content});

  Map<String, dynamic> toJson() => {
        'mode': 'replace',
        'content': content,
      };
}

// ---------------------------------------------------------------------------
// Permission Types
// ---------------------------------------------------------------------------

/// Permission request from the CLI server.
class PermissionRequest {
  final String kind;
  final String? toolCallId;
  final Map<String, dynamic> extra;

  const PermissionRequest({
    required this.kind,
    this.toolCallId,
    this.extra = const {},
  });

  factory PermissionRequest.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String;
    final toolCallId = json['toolCallId'] as String?;
    final extra = Map<String, dynamic>.from(json)
      ..remove('kind')
      ..remove('toolCallId');
    return PermissionRequest(kind: kind, toolCallId: toolCallId, extra: extra);
  }
}

/// Result of a permission decision.
class PermissionRequestResult {
  /// One of: approved, denied-by-rules,
  /// denied-no-approval-rule-and-could-not-request-from-user,
  /// denied-interactively-by-user
  final String kind;
  final List<dynamic>? rules;

  const PermissionRequestResult({required this.kind, this.rules});

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (rules != null) 'rules': rules,
      };
}

/// Handler for permission requests.
typedef PermissionHandler = Future<PermissionRequestResult> Function(
  PermissionRequest request,
  SessionInvocationContext context,
);

// ---------------------------------------------------------------------------
// User Input Types
// ---------------------------------------------------------------------------

/// Request for user input from the agent (enables ask_user tool).
class UserInputRequest {
  final String question;
  final List<String>? choices;
  final bool allowFreeform;

  const UserInputRequest({
    required this.question,
    this.choices,
    this.allowFreeform = true,
  });

  factory UserInputRequest.fromJson(Map<String, dynamic> json) {
    return UserInputRequest(
      question: json['question'] as String,
      choices: (json['choices'] as List<dynamic>?)?.cast<String>(),
      allowFreeform: json['allowFreeform'] as bool? ?? true,
    );
  }
}

/// Response to a user input request.
class UserInputResponse {
  final String answer;
  final bool wasFreeform;

  const UserInputResponse({required this.answer, required this.wasFreeform});

  Map<String, dynamic> toJson() => {
        'answer': answer,
        'wasFreeform': wasFreeform,
      };
}

/// Handler for user input requests.
typedef UserInputHandler = Future<UserInputResponse> Function(
  UserInputRequest request,
  SessionInvocationContext context,
);

// ---------------------------------------------------------------------------
// Session Invocation Context (shared by permission / input / hooks)
// ---------------------------------------------------------------------------

/// Minimal context passed to permission, user-input and hook handlers.
class SessionInvocationContext {
  final String sessionId;
  const SessionInvocationContext({required this.sessionId});
}

// ---------------------------------------------------------------------------
// Hook Types
// ---------------------------------------------------------------------------

/// Base input fields shared by all hooks.
class BaseHookInput {
  final int timestamp;
  final String cwd;

  const BaseHookInput({required this.timestamp, required this.cwd});

  factory BaseHookInput.fromJson(Map<String, dynamic> json) {
    return BaseHookInput(
      timestamp: json['timestamp'] as int,
      cwd: json['cwd'] as String,
    );
  }
}

/// Input for pre-tool-use hook.
class PreToolUseHookInput extends BaseHookInput {
  final String toolName;
  final dynamic toolArgs;

  PreToolUseHookInput({
    required super.timestamp,
    required super.cwd,
    required this.toolName,
    this.toolArgs,
  });

  factory PreToolUseHookInput.fromJson(Map<String, dynamic> json) {
    return PreToolUseHookInput(
      timestamp: json['timestamp'] as int,
      cwd: json['cwd'] as String,
      toolName: json['toolName'] as String,
      toolArgs: json['toolArgs'],
    );
  }
}

/// Output for pre-tool-use hook.
class PreToolUseHookOutput {
  /// One of: allow, deny, ask (or null to use default)
  final String? permissionDecision;
  final String? permissionDecisionReason;
  final dynamic modifiedArgs;
  final String? additionalContext;
  final bool? suppressOutput;

  const PreToolUseHookOutput({
    this.permissionDecision,
    this.permissionDecisionReason,
    this.modifiedArgs,
    this.additionalContext,
    this.suppressOutput,
  });

  Map<String, dynamic> toJson() => {
        if (permissionDecision != null) 'permissionDecision': permissionDecision,
        if (permissionDecisionReason != null)
          'permissionDecisionReason': permissionDecisionReason,
        if (modifiedArgs != null) 'modifiedArgs': modifiedArgs,
        if (additionalContext != null) 'additionalContext': additionalContext,
        if (suppressOutput != null) 'suppressOutput': suppressOutput,
      };
}

typedef PreToolUseHandler = Future<PreToolUseHookOutput?> Function(
  PreToolUseHookInput input,
  SessionInvocationContext context,
);

/// Input for post-tool-use hook.
class PostToolUseHookInput extends BaseHookInput {
  final String toolName;
  final dynamic toolArgs;
  final ToolResultObject toolResult;

  PostToolUseHookInput({
    required super.timestamp,
    required super.cwd,
    required this.toolName,
    this.toolArgs,
    required this.toolResult,
  });

  factory PostToolUseHookInput.fromJson(Map<String, dynamic> json) {
    return PostToolUseHookInput(
      timestamp: json['timestamp'] as int,
      cwd: json['cwd'] as String,
      toolName: json['toolName'] as String,
      toolArgs: json['toolArgs'],
      toolResult:
          ToolResultObject.fromJson(json['toolResult'] as Map<String, dynamic>),
    );
  }
}

/// Output for post-tool-use hook.
class PostToolUseHookOutput {
  final ToolResultObject? modifiedResult;
  final String? additionalContext;
  final bool? suppressOutput;

  const PostToolUseHookOutput({
    this.modifiedResult,
    this.additionalContext,
    this.suppressOutput,
  });

  Map<String, dynamic> toJson() => {
        if (modifiedResult != null) 'modifiedResult': modifiedResult!.toJson(),
        if (additionalContext != null) 'additionalContext': additionalContext,
        if (suppressOutput != null) 'suppressOutput': suppressOutput,
      };
}

typedef PostToolUseHandler = Future<PostToolUseHookOutput?> Function(
  PostToolUseHookInput input,
  SessionInvocationContext context,
);

/// Input for user-prompt-submitted hook.
class UserPromptSubmittedHookInput extends BaseHookInput {
  final String prompt;

  UserPromptSubmittedHookInput({
    required super.timestamp,
    required super.cwd,
    required this.prompt,
  });

  factory UserPromptSubmittedHookInput.fromJson(Map<String, dynamic> json) {
    return UserPromptSubmittedHookInput(
      timestamp: json['timestamp'] as int,
      cwd: json['cwd'] as String,
      prompt: json['prompt'] as String,
    );
  }
}

/// Output for user-prompt-submitted hook.
class UserPromptSubmittedHookOutput {
  final String? modifiedPrompt;
  final String? additionalContext;
  final bool? suppressOutput;

  const UserPromptSubmittedHookOutput({
    this.modifiedPrompt,
    this.additionalContext,
    this.suppressOutput,
  });

  Map<String, dynamic> toJson() => {
        if (modifiedPrompt != null) 'modifiedPrompt': modifiedPrompt,
        if (additionalContext != null) 'additionalContext': additionalContext,
        if (suppressOutput != null) 'suppressOutput': suppressOutput,
      };
}

typedef UserPromptSubmittedHandler
    = Future<UserPromptSubmittedHookOutput?> Function(
  UserPromptSubmittedHookInput input,
  SessionInvocationContext context,
);

/// Input for session-start hook.
class SessionStartHookInput extends BaseHookInput {
  /// One of: startup, resume, new
  final String source;
  final String? initialPrompt;

  SessionStartHookInput({
    required super.timestamp,
    required super.cwd,
    required this.source,
    this.initialPrompt,
  });

  factory SessionStartHookInput.fromJson(Map<String, dynamic> json) {
    return SessionStartHookInput(
      timestamp: json['timestamp'] as int,
      cwd: json['cwd'] as String,
      source: json['source'] as String,
      initialPrompt: json['initialPrompt'] as String?,
    );
  }
}

/// Output for session-start hook.
class SessionStartHookOutput {
  final String? additionalContext;
  final Map<String, dynamic>? modifiedConfig;

  const SessionStartHookOutput({this.additionalContext, this.modifiedConfig});

  Map<String, dynamic> toJson() => {
        if (additionalContext != null) 'additionalContext': additionalContext,
        if (modifiedConfig != null) 'modifiedConfig': modifiedConfig,
      };
}

typedef SessionStartHandler = Future<SessionStartHookOutput?> Function(
  SessionStartHookInput input,
  SessionInvocationContext context,
);

/// Input for session-end hook.
class SessionEndHookInput extends BaseHookInput {
  /// One of: complete, error, abort, timeout, user_exit
  final String reason;
  final String? finalMessage;
  final String? error;

  SessionEndHookInput({
    required super.timestamp,
    required super.cwd,
    required this.reason,
    this.finalMessage,
    this.error,
  });

  factory SessionEndHookInput.fromJson(Map<String, dynamic> json) {
    return SessionEndHookInput(
      timestamp: json['timestamp'] as int,
      cwd: json['cwd'] as String,
      reason: json['reason'] as String,
      finalMessage: json['finalMessage'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// Output for session-end hook.
class SessionEndHookOutput {
  final bool? suppressOutput;
  final List<String>? cleanupActions;
  final String? sessionSummary;

  const SessionEndHookOutput({
    this.suppressOutput,
    this.cleanupActions,
    this.sessionSummary,
  });

  Map<String, dynamic> toJson() => {
        if (suppressOutput != null) 'suppressOutput': suppressOutput,
        if (cleanupActions != null) 'cleanupActions': cleanupActions,
        if (sessionSummary != null) 'sessionSummary': sessionSummary,
      };
}

typedef SessionEndHandler = Future<SessionEndHookOutput?> Function(
  SessionEndHookInput input,
  SessionInvocationContext context,
);

/// Input for error-occurred hook.
class ErrorOccurredHookInput extends BaseHookInput {
  final String error;

  /// One of: model_call, tool_execution, system, user_input
  final String errorContext;
  final bool recoverable;

  ErrorOccurredHookInput({
    required super.timestamp,
    required super.cwd,
    required this.error,
    required this.errorContext,
    required this.recoverable,
  });

  factory ErrorOccurredHookInput.fromJson(Map<String, dynamic> json) {
    return ErrorOccurredHookInput(
      timestamp: json['timestamp'] as int,
      cwd: json['cwd'] as String,
      error: json['error'] as String,
      errorContext: json['errorContext'] as String,
      recoverable: json['recoverable'] as bool,
    );
  }
}

/// Output for error-occurred hook.
class ErrorOccurredHookOutput {
  final bool? suppressOutput;

  /// One of: retry, skip, abort
  final String? errorHandling;
  final int? retryCount;
  final String? userNotification;

  const ErrorOccurredHookOutput({
    this.suppressOutput,
    this.errorHandling,
    this.retryCount,
    this.userNotification,
  });

  Map<String, dynamic> toJson() => {
        if (suppressOutput != null) 'suppressOutput': suppressOutput,
        if (errorHandling != null) 'errorHandling': errorHandling,
        if (retryCount != null) 'retryCount': retryCount,
        if (userNotification != null) 'userNotification': userNotification,
      };
}

typedef ErrorOccurredHandler = Future<ErrorOccurredHookOutput?> Function(
  ErrorOccurredHookInput input,
  SessionInvocationContext context,
);

/// Configuration for session hooks.
class SessionHooks {
  final PreToolUseHandler? onPreToolUse;
  final PostToolUseHandler? onPostToolUse;
  final UserPromptSubmittedHandler? onUserPromptSubmitted;
  final SessionStartHandler? onSessionStart;
  final SessionEndHandler? onSessionEnd;
  final ErrorOccurredHandler? onErrorOccurred;

  const SessionHooks({
    this.onPreToolUse,
    this.onPostToolUse,
    this.onUserPromptSubmitted,
    this.onSessionStart,
    this.onSessionEnd,
    this.onErrorOccurred,
  });

  /// Returns true if any hook handler is set.
  bool get hasAny =>
      onPreToolUse != null ||
      onPostToolUse != null ||
      onUserPromptSubmitted != null ||
      onSessionStart != null ||
      onSessionEnd != null ||
      onErrorOccurred != null;
}

// ---------------------------------------------------------------------------
// MCP Server Configuration
// ---------------------------------------------------------------------------

/// Base MCP server configuration.
abstract class MCPServerConfig {
  /// List of tools to include from this server. [] means none, ['*'] means all.
  final List<String> tools;

  /// "local", "stdio", "http", or "sse"
  final String? type;

  /// Optional timeout in milliseconds for tool calls.
  final int? timeout;

  const MCPServerConfig({required this.tools, this.type, this.timeout});

  Map<String, dynamic> toJson();
}

/// Configuration for a local / stdio MCP server.
class MCPLocalServerConfig extends MCPServerConfig {
  final String command;
  final List<String> args;
  final Map<String, String>? env;
  final String? cwd;

  const MCPLocalServerConfig({
    required super.tools,
    super.type,
    super.timeout,
    required this.command,
    required this.args,
    this.env,
    this.cwd,
  });

  @override
  Map<String, dynamic> toJson() => {
        'tools': tools,
        if (type != null) 'type': type,
        if (timeout != null) 'timeout': timeout,
        'command': command,
        'args': args,
        if (env != null) 'env': env,
        if (cwd != null) 'cwd': cwd,
      };
}

/// Configuration for a remote MCP server (HTTP or SSE).
class MCPRemoteServerConfig extends MCPServerConfig {
  final String url;
  final Map<String, String>? headers;

  const MCPRemoteServerConfig({
    required super.tools,
    required String super.type,
    super.timeout,
    required this.url,
    this.headers,
  });

  @override
  Map<String, dynamic> toJson() => {
        'tools': tools,
        'type': type,
        if (timeout != null) 'timeout': timeout,
        'url': url,
        if (headers != null) 'headers': headers,
      };
}

// ---------------------------------------------------------------------------
// Custom Agent Configuration
// ---------------------------------------------------------------------------

/// Configuration for a custom agent.
class CustomAgentConfig {
  final String name;
  final String? displayName;
  final String? description;
  final List<String>? tools;
  final String prompt;
  final Map<String, MCPServerConfig>? mcpServers;
  final bool? infer;

  const CustomAgentConfig({
    required this.name,
    this.displayName,
    this.description,
    this.tools,
    required this.prompt,
    this.mcpServers,
    this.infer,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        if (displayName != null) 'displayName': displayName,
        if (description != null) 'description': description,
        if (tools != null) 'tools': tools,
        'prompt': prompt,
        if (mcpServers != null)
          'mcpServers':
              mcpServers!.map((k, v) => MapEntry(k, v.toJson())),
        if (infer != null) 'infer': infer,
      };
}

// ---------------------------------------------------------------------------
// Infinite Session Configuration
// ---------------------------------------------------------------------------

/// Configuration for infinite sessions with automatic context compaction.
class InfiniteSessionConfig {
  final bool? enabled;
  final double? backgroundCompactionThreshold;
  final double? bufferExhaustionThreshold;

  const InfiniteSessionConfig({
    this.enabled,
    this.backgroundCompactionThreshold,
    this.bufferExhaustionThreshold,
  });

  Map<String, dynamic> toJson() => {
        if (enabled != null) 'enabled': enabled,
        if (backgroundCompactionThreshold != null)
          'backgroundCompactionThreshold': backgroundCompactionThreshold,
        if (bufferExhaustionThreshold != null)
          'bufferExhaustionThreshold': bufferExhaustionThreshold,
      };
}

// ---------------------------------------------------------------------------
// Provider Configuration (BYOK)
// ---------------------------------------------------------------------------

/// Configuration for a custom API provider.
class ProviderConfig {
  /// One of: openai, azure, anthropic
  final String? type;

  /// One of: completions, responses
  final String? wireApi;

  final String baseUrl;
  final String? apiKey;
  final String? bearerToken;
  final AzureProviderOptions? azure;

  const ProviderConfig({
    this.type,
    this.wireApi,
    required this.baseUrl,
    this.apiKey,
    this.bearerToken,
    this.azure,
  });

  Map<String, dynamic> toJson() => {
        if (type != null) 'type': type,
        if (wireApi != null) 'wireApi': wireApi,
        'baseUrl': baseUrl,
        if (apiKey != null) 'apiKey': apiKey,
        if (bearerToken != null) 'bearerToken': bearerToken,
        if (azure != null) 'azure': azure!.toJson(),
      };
}

/// Azure-specific provider options.
class AzureProviderOptions {
  final String? apiVersion;

  const AzureProviderOptions({this.apiVersion});

  Map<String, dynamic> toJson() => {
        if (apiVersion != null) 'apiVersion': apiVersion,
      };
}

// ---------------------------------------------------------------------------
// Ping Response
// ---------------------------------------------------------------------------

/// Response from a ping request.
class PingResponse {
  final String message;
  final int timestamp;
  final int? protocolVersion;

  const PingResponse({
    required this.message,
    required this.timestamp,
    this.protocolVersion,
  });

  factory PingResponse.fromJson(Map<String, dynamic> json) {
    return PingResponse(
      message: json['message'] as String? ?? '',
      timestamp: json['timestamp'] as int,
      protocolVersion: json['protocolVersion'] as int?,
    );
  }
}

// ---------------------------------------------------------------------------
// Model Types
// ---------------------------------------------------------------------------

/// Model capabilities and limits.
class ModelCapabilities {
  final ModelSupports supports;
  final ModelLimits limits;

  const ModelCapabilities({required this.supports, required this.limits});

  factory ModelCapabilities.fromJson(Map<String, dynamic> json) {
    return ModelCapabilities(
      supports:
          ModelSupports.fromJson(json['supports'] as Map<String, dynamic>),
      limits: ModelLimits.fromJson(json['limits'] as Map<String, dynamic>),
    );
  }
}

class ModelSupports {
  final bool vision;
  final bool reasoningEffort;

  const ModelSupports({required this.vision, required this.reasoningEffort});

  factory ModelSupports.fromJson(Map<String, dynamic> json) {
    return ModelSupports(
      vision: json['vision'] as bool? ?? false,
      reasoningEffort: json['reasoningEffort'] as bool? ?? false,
    );
  }
}

class ModelLimits {
  final int? maxPromptTokens;
  final int maxContextWindowTokens;

  const ModelLimits({this.maxPromptTokens, required this.maxContextWindowTokens});

  factory ModelLimits.fromJson(Map<String, dynamic> json) {
    return ModelLimits(
      maxPromptTokens: json['max_prompt_tokens'] as int?,
      maxContextWindowTokens: json['max_context_window_tokens'] as int,
    );
  }
}

/// Model policy state.
class ModelPolicy {
  final String state;
  final String terms;

  const ModelPolicy({required this.state, required this.terms});

  factory ModelPolicy.fromJson(Map<String, dynamic> json) {
    return ModelPolicy(
      state: json['state'] as String,
      terms: json['terms'] as String,
    );
  }
}

/// Model billing information.
class ModelBilling {
  final double multiplier;

  const ModelBilling({required this.multiplier});

  factory ModelBilling.fromJson(Map<String, dynamic> json) {
    return ModelBilling(
      multiplier: (json['multiplier'] as num).toDouble(),
    );
  }
}

/// Information about an available model.
class ModelInfo {
  final String id;
  final String name;
  final ModelCapabilities capabilities;
  final ModelPolicy? policy;
  final ModelBilling? billing;
  final List<String>? supportedReasoningEfforts;
  final String? defaultReasoningEffort;

  const ModelInfo({
    required this.id,
    required this.name,
    required this.capabilities,
    this.policy,
    this.billing,
    this.supportedReasoningEfforts,
    this.defaultReasoningEffort,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> json) {
    return ModelInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      capabilities: ModelCapabilities.fromJson(
          json['capabilities'] as Map<String, dynamic>),
      policy: json['policy'] != null
          ? ModelPolicy.fromJson(json['policy'] as Map<String, dynamic>)
          : null,
      billing: json['billing'] != null
          ? ModelBilling.fromJson(json['billing'] as Map<String, dynamic>)
          : null,
      supportedReasoningEfforts:
          (json['supportedReasoningEfforts'] as List<dynamic>?)
              ?.cast<String>(),
      defaultReasoningEffort: json['defaultReasoningEffort'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// Session Metadata
// ---------------------------------------------------------------------------

/// Metadata about a session.
class SessionMetadata {
  final String sessionId;
  final DateTime startTime;
  final DateTime modifiedTime;
  final String? summary;
  final bool isRemote;

  const SessionMetadata({
    required this.sessionId,
    required this.startTime,
    required this.modifiedTime,
    this.summary,
    required this.isRemote,
  });

  factory SessionMetadata.fromJson(Map<String, dynamic> json) {
    return SessionMetadata(
      sessionId: json['sessionId'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      modifiedTime: DateTime.parse(json['modifiedTime'] as String),
      summary: json['summary'] as String?,
      isRemote: json['isRemote'] as bool? ?? false,
    );
  }
}

// ---------------------------------------------------------------------------
// Session Lifecycle Events
// ---------------------------------------------------------------------------

/// Session lifecycle event notification.
class SessionLifecycleEvent {
  /// One of: session.created, session.deleted, session.updated,
  /// session.foreground, session.background
  final String type;

  final String sessionId;

  final Map<String, dynamic>? metadata;

  const SessionLifecycleEvent({
    required this.type,
    required this.sessionId,
    this.metadata,
  });

  factory SessionLifecycleEvent.fromJson(Map<String, dynamic> json) {
    return SessionLifecycleEvent(
      type: json['type'] as String,
      sessionId: json['sessionId'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Handler for session lifecycle events.
typedef SessionLifecycleHandler = void Function(SessionLifecycleEvent event);

// ---------------------------------------------------------------------------
// Response Format & Image Generation
// ---------------------------------------------------------------------------

/// Response format for message responses.
enum ResponseFormat {
  text,
  image,
  jsonObject;

  String toJson() {
    switch (this) {
      case ResponseFormat.text:
        return 'text';
      case ResponseFormat.image:
        return 'image';
      case ResponseFormat.jsonObject:
        return 'json_object';
    }
  }
}

/// Options for image generation.
class ImageOptions {
  /// Image size (e.g. "1024x1024").
  final String? size;

  /// Image quality ("hd" or "standard").
  final String? quality;

  /// Image style ("natural" or "vivid").
  final String? style;

  const ImageOptions({this.size, this.quality, this.style});

  Map<String, dynamic> toJson() => {
        if (size != null) 'size': size,
        if (quality != null) 'quality': quality,
        if (style != null) 'style': style,
      };
}

/// Image data from an assistant image response.
class AssistantImageData {
  final String format;
  final String base64;
  final String? url;
  final String? revisedPrompt;
  final int width;
  final int height;

  const AssistantImageData({
    required this.format,
    required this.base64,
    this.url,
    this.revisedPrompt,
    required this.width,
    required this.height,
  });

  factory AssistantImageData.fromJson(Map<String, dynamic> json) {
    return AssistantImageData(
      format: json['format'] as String,
      base64: json['base64'] as String,
      url: json['url'] as String?,
      revisedPrompt: json['revisedPrompt'] as String?,
      width: json['width'] as int,
      height: json['height'] as int,
    );
  }
}

/// A content block in a mixed text+image response.
class ContentBlock {
  final String type;
  final String? text;
  final AssistantImageData? image;

  const ContentBlock({required this.type, this.text, this.image});

  factory ContentBlock.fromJson(Map<String, dynamic> json) {
    return ContentBlock(
      type: json['type'] as String,
      text: json['text'] as String?,
      image: json['image'] != null
          ? AssistantImageData.fromJson(json['image'] as Map<String, dynamic>)
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Message Options
// ---------------------------------------------------------------------------

/// File attachment for a message.
class FileAttachment {
  final String path;
  final String? displayName;

  const FileAttachment({required this.path, this.displayName});

  Map<String, dynamic> toJson() => {
        'type': 'file',
        'path': path,
        if (displayName != null) 'displayName': displayName,
      };
}

/// Directory attachment for a message.
class DirectoryAttachment {
  final String path;
  final String? displayName;

  const DirectoryAttachment({required this.path, this.displayName});

  Map<String, dynamic> toJson() => {
        'type': 'directory',
        'path': path,
        if (displayName != null) 'displayName': displayName,
      };
}

/// Selection range within a file.
class SelectionRange {
  final int startLine;
  final int startCharacter;
  final int endLine;
  final int endCharacter;

  const SelectionRange({
    required this.startLine,
    required this.startCharacter,
    required this.endLine,
    required this.endCharacter,
  });

  Map<String, dynamic> toJson() => {
        'start': {'line': startLine, 'character': startCharacter},
        'end': {'line': endLine, 'character': endCharacter},
      };
}

/// Selection attachment for a message.
class SelectionAttachment {
  final String filePath;
  final String displayName;
  final SelectionRange? selection;
  final String? text;

  const SelectionAttachment({
    required this.filePath,
    required this.displayName,
    this.selection,
    this.text,
  });

  Map<String, dynamic> toJson() => {
        'type': 'selection',
        'filePath': filePath,
        'displayName': displayName,
        if (selection != null) 'selection': selection!.toJson(),
        if (text != null) 'text': text,
      };
}

/// Options for sending a message to a session.
class MessageOptions {
  final String prompt;
  final List<Map<String, dynamic>>? attachments;

  /// One of: enqueue, immediate
  final String? mode;

  /// Desired response format (text, image, or json_object).
  final ResponseFormat? responseFormat;

  /// Options for image generation (used when [responseFormat] is image).
  final ImageOptions? imageOptions;

  const MessageOptions({
    required this.prompt,
    this.attachments,
    this.mode,
    this.responseFormat,
    this.imageOptions,
  });
}

// ---------------------------------------------------------------------------
// Session Configuration
// ---------------------------------------------------------------------------

/// Configuration for creating a session.
class SessionConfig {
  final String? sessionId;
  final String? model;
  final String? reasoningEffort;
  final String? configDir;
  final List<Tool>? tools;

  /// Either [SystemMessageAppendConfig] or [SystemMessageReplaceConfig].
  final dynamic systemMessage;

  final List<String>? availableTools;
  final List<String>? excludedTools;
  final ProviderConfig? provider;
  final PermissionHandler? onPermissionRequest;
  final UserInputHandler? onUserInputRequest;
  final SessionHooks? hooks;
  final String? workingDirectory;
  final bool? streaming;
  final Map<String, MCPServerConfig>? mcpServers;
  final List<CustomAgentConfig>? customAgents;
  final List<String>? skillDirectories;
  final List<String>? disabledSkills;
  final InfiniteSessionConfig? infiniteSessions;

  const SessionConfig({
    this.sessionId,
    this.model,
    this.reasoningEffort,
    this.configDir,
    this.tools,
    this.systemMessage,
    this.availableTools,
    this.excludedTools,
    this.provider,
    this.onPermissionRequest,
    this.onUserInputRequest,
    this.hooks,
    this.workingDirectory,
    this.streaming,
    this.mcpServers,
    this.customAgents,
    this.skillDirectories,
    this.disabledSkills,
    this.infiniteSessions,
  });
}

/// Configuration for resuming a session.
class ResumeSessionConfig {
  final String? model;
  final String? reasoningEffort;
  final String? configDir;
  final List<Tool>? tools;
  final dynamic systemMessage;
  final List<String>? availableTools;
  final List<String>? excludedTools;
  final ProviderConfig? provider;
  final PermissionHandler? onPermissionRequest;
  final UserInputHandler? onUserInputRequest;
  final SessionHooks? hooks;
  final String? workingDirectory;
  final bool? streaming;
  final Map<String, MCPServerConfig>? mcpServers;
  final List<CustomAgentConfig>? customAgents;
  final List<String>? skillDirectories;
  final List<String>? disabledSkills;
  final InfiniteSessionConfig? infiniteSessions;
  final bool? disableResume;

  const ResumeSessionConfig({
    this.model,
    this.reasoningEffort,
    this.configDir,
    this.tools,
    this.systemMessage,
    this.availableTools,
    this.excludedTools,
    this.provider,
    this.onPermissionRequest,
    this.onUserInputRequest,
    this.hooks,
    this.workingDirectory,
    this.streaming,
    this.mcpServers,
    this.customAgents,
    this.skillDirectories,
    this.disabledSkills,
    this.infiniteSessions,
    this.disableResume,
  });
}

// ---------------------------------------------------------------------------
// Client Options
// ---------------------------------------------------------------------------

/// Options for creating a [CopilotClient].
class CopilotClientOptions {
  /// Path to the CLI executable.
  final String? cliPath;

  /// Extra arguments inserted before SDK-managed args.
  final List<String>? cliArgs;

  /// Working directory for the CLI process.
  final String? cwd;

  /// Port for TCP mode. 0 means random available port.
  final int? port;

  /// Use stdio transport instead of TCP. Defaults to true.
  final bool? useStdio;

  /// URL of an existing Copilot CLI server (TCP only).
  /// Mutually exclusive with [cliPath] and [useStdio].
  final String? cliUrl;

  /// Log level for the CLI server.
  final String? logLevel;

  /// Auto-start the CLI server on first use. Defaults to true.
  final bool? autoStart;

  /// Auto-restart the CLI if it crashes. Defaults to true.
  final bool? autoRestart;

  /// Environment variables for the CLI process.
  final Map<String, String>? env;

  /// GitHub token for authentication.
  final String? githubToken;

  /// Whether to use logged-in user auth. Defaults to true
  /// (false when [githubToken] is provided).
  final bool? useLoggedInUser;

  const CopilotClientOptions({
    this.cliPath,
    this.cliArgs,
    this.cwd,
    this.port,
    this.useStdio,
    this.cliUrl,
    this.logLevel,
    this.autoStart,
    this.autoRestart,
    this.env,
    this.githubToken,
    this.useLoggedInUser,
  });
}

// ---------------------------------------------------------------------------
// Status / Auth Responses
// ---------------------------------------------------------------------------

/// Response from status.get.
class GetStatusResponse {
  final String version;
  final int protocolVersion;

  const GetStatusResponse(
      {required this.version, required this.protocolVersion});

  factory GetStatusResponse.fromJson(Map<String, dynamic> json) {
    return GetStatusResponse(
      version: json['version'] as String,
      protocolVersion: json['protocolVersion'] as int,
    );
  }
}

/// Response from auth.getStatus.
class GetAuthStatusResponse {
  final bool isAuthenticated;
  final String? authType;
  final String? host;
  final String? login;
  final String? statusMessage;

  const GetAuthStatusResponse({
    required this.isAuthenticated,
    this.authType,
    this.host,
    this.login,
    this.statusMessage,
  });

  factory GetAuthStatusResponse.fromJson(Map<String, dynamic> json) {
    return GetAuthStatusResponse(
      isAuthenticated: json['isAuthenticated'] as bool,
      authType: json['authType'] as String?,
      host: json['host'] as String?,
      login: json['login'] as String?,
      statusMessage: json['statusMessage'] as String?,
    );
  }
}
