# frozen_string_literal: true

# Copyright (c) Microsoft Corporation. All rights reserved.

require "json"

module Copilot
  # Connection state of the client.
  # Valid values: "disconnected", "connecting", "connected", "error"
  module ConnectionState
    DISCONNECTED = "disconnected"
    CONNECTING   = "connecting"
    CONNECTED    = "connected"
    ERROR        = "error"
  end

  # Tool result type constants.
  module ToolResultType
    SUCCESS  = "success"
    FAILURE  = "failure"
    REJECTED = "rejected"
    DENIED   = "denied"
  end

  # A binary payload returned by a tool.
  ToolBinaryResult = Struct.new(
    :data, :mime_type, :type, :description,
    keyword_init: true
  ) do
    def to_h
      h = { data: data, mimeType: mime_type, type: type }
      h[:description] = description if description
      h
    end
  end

  # The result of a tool invocation.
  # Can be constructed directly or returned as a plain Hash / String from a handler.
  ToolResult = Struct.new(
    :text_result_for_llm, :result_type,
    :binary_results_for_llm, :error, :session_log, :tool_telemetry,
    keyword_init: true
  ) do
    def to_h
      h = {
        textResultForLlm: text_result_for_llm,
        resultType: result_type || ToolResultType::SUCCESS,
      }
      h[:binaryResultsForLlm] = binary_results_for_llm.map(&:to_h) if binary_results_for_llm
      h[:error] = error if error
      h[:sessionLog] = session_log if session_log
      h[:toolTelemetry] = tool_telemetry || {}
      h
    end
  end

  # Context provided to a tool handler when invoked.
  ToolInvocation = Struct.new(
    :session_id, :tool_call_id, :tool_name, :arguments,
    keyword_init: true
  )

  # A tool definition. +handler+ is a callable (Proc/lambda/method) that receives
  # (arguments, invocation) and returns a result (String, Hash, or ToolResult).
  Tool = Struct.new(
    :name, :description, :parameters, :handler,
    keyword_init: true
  ) do
    # @return [Hash] wire-format representation sent to the server
    def to_wire
      h = { name: name }
      h[:description] = description if description
      h[:parameters] = parameters if parameters
      h
    end
  end

  # System message in append mode (default).
  SystemMessageAppendConfig = Struct.new(:mode, :content, keyword_init: true) do
    def to_h
      h = {}
      h[:mode] = mode || "append"
      h[:content] = content if content
      h
    end
  end

  # System message in replace mode - caller provides entire system message.
  SystemMessageReplaceConfig = Struct.new(:content, keyword_init: true) do
    def to_h
      { mode: "replace", content: content }
    end
  end

  # Permission request from the server.
  PermissionRequest = Struct.new(:kind, :tool_call_id, :extra, keyword_init: true) do
    def self.from_hash(h)
      new(
        kind: h["kind"],
        tool_call_id: h["toolCallId"],
        extra: h.reject { |k, _| %w[kind toolCallId].include?(k) }
      )
    end
  end

  # Result of a permission request.
  PermissionRequestResult = Struct.new(:kind, :rules, keyword_init: true) do
    def to_h
      h = { kind: kind }
      h[:rules] = rules if rules
      h
    end
  end

  # Permission result kind constants.
  module PermissionKind
    APPROVED = "approved"
    DENIED_BY_RULES = "denied-by-rules"
    DENIED_NO_APPROVAL = "denied-no-approval-rule-and-could-not-request-from-user"
    DENIED_BY_USER = "denied-interactively-by-user"
  end

  # Request for user input from the agent (enables ask_user tool).
  UserInputRequest = Struct.new(:question, :choices, :allow_freeform, keyword_init: true) do
    def self.from_hash(h)
      new(
        question: h["question"],
        choices: h["choices"],
        allow_freeform: h.fetch("allowFreeform", true)
      )
    end
  end

  # Response to a user input request.
  UserInputResponse = Struct.new(:answer, :was_freeform, keyword_init: true) do
    def to_h
      { answer: answer, wasFreeform: was_freeform }
    end
  end

  # Custom API provider configuration (BYOK).
  ProviderConfig = Struct.new(
    :type, :wire_api, :base_url, :api_key, :bearer_token, :azure,
    keyword_init: true
  ) do
    def to_wire
      h = {}
      h[:type] = type if type
      h[:wireApi] = wire_api if wire_api
      h[:baseUrl] = base_url if base_url
      h[:apiKey] = api_key if api_key
      h[:bearerToken] = bearer_token if bearer_token
      if azure
        az = {}
        az[:apiVersion] = azure[:api_version] if azure[:api_version]
        h[:azure] = az unless az.empty?
      end
      h
    end
  end

  # MCP local/stdio server configuration.
  MCPLocalServerConfig = Struct.new(
    :tools, :type, :timeout, :command, :args, :env, :cwd,
    keyword_init: true
  ) do
    def to_h
      h = { tools: tools || [], command: command, args: args || [] }
      h[:type] = type if type
      h[:timeout] = timeout if timeout
      h[:env] = env if env
      h[:cwd] = cwd if cwd
      h
    end
  end

  # MCP remote server configuration (HTTP or SSE).
  MCPRemoteServerConfig = Struct.new(
    :tools, :type, :timeout, :url, :headers,
    keyword_init: true
  ) do
    def to_h
      h = { tools: tools || [], type: type, url: url }
      h[:timeout] = timeout if timeout
      h[:headers] = headers if headers
      h
    end
  end

  # Custom agent configuration.
  CustomAgentConfig = Struct.new(
    :name, :display_name, :description, :tools, :prompt, :mcp_servers, :infer,
    keyword_init: true
  ) do
    def to_wire
      h = { name: name, prompt: prompt }
      h[:displayName] = display_name if display_name
      h[:description] = description if description
      h[:tools] = tools if tools
      h[:mcpServers] = mcp_servers if mcp_servers
      h[:infer] = infer unless infer.nil?
      h
    end
  end

  # Infinite session configuration for automatic context compaction and workspace persistence.
  InfiniteSessionConfig = Struct.new(
    :enabled, :background_compaction_threshold, :buffer_exhaustion_threshold,
    keyword_init: true
  ) do
    def to_wire
      h = {}
      h[:enabled] = enabled unless enabled.nil?
      h[:backgroundCompactionThreshold] = background_compaction_threshold if background_compaction_threshold
      h[:bufferExhaustionThreshold] = buffer_exhaustion_threshold if buffer_exhaustion_threshold
      h
    end
  end

  # Configuration for creating a session.
  SessionConfig = Struct.new(
    :session_id, :model, :reasoning_effort, :config_dir,
    :tools, :system_message, :available_tools, :excluded_tools,
    :provider, :on_permission_request, :on_user_input_request, :hooks,
    :working_directory, :streaming, :mcp_servers, :custom_agents,
    :skill_directories, :disabled_skills, :infinite_sessions,
    keyword_init: true
  )

  # Configuration for resuming a session. Same fields as SessionConfig plus disable_resume.
  ResumeSessionConfig = Struct.new(
    :model, :reasoning_effort, :config_dir,
    :tools, :system_message, :available_tools, :excluded_tools,
    :provider, :on_permission_request, :on_user_input_request, :hooks,
    :working_directory, :streaming, :mcp_servers, :custom_agents,
    :skill_directories, :disabled_skills, :infinite_sessions,
    :disable_resume,
    keyword_init: true
  )

  # Options for sending a message.
  MessageOptions = Struct.new(:prompt, :attachments, :mode, keyword_init: true)

  # Ping response from the server.
  PingResponse = Struct.new(:message, :timestamp, :protocol_version, keyword_init: true) do
    def self.from_hash(h)
      new(
        message: h["message"],
        timestamp: h["timestamp"],
        protocol_version: h["protocolVersion"]
      )
    end
  end

  # Response from status.get.
  GetStatusResponse = Struct.new(:version, :protocol_version, keyword_init: true) do
    def self.from_hash(h)
      new(version: h["version"], protocol_version: h["protocolVersion"])
    end
  end

  # Response from auth.getStatus.
  GetAuthStatusResponse = Struct.new(
    :is_authenticated, :auth_type, :host, :login, :status_message,
    keyword_init: true
  ) do
    def self.from_hash(h)
      new(
        is_authenticated: h["isAuthenticated"],
        auth_type: h["authType"],
        host: h["host"],
        login: h["login"],
        status_message: h["statusMessage"]
      )
    end
  end

  # Model support flags.
  ModelSupports = Struct.new(:vision, :reasoning_effort, keyword_init: true) do
    def self.from_hash(h)
      new(vision: h["vision"], reasoning_effort: h["reasoningEffort"])
    end
  end

  # Model vision limits.
  ModelVisionLimits = Struct.new(
    :supported_media_types, :max_prompt_images, :max_prompt_image_size,
    keyword_init: true
  ) do
    def self.from_hash(h)
      new(
        supported_media_types: h["supported_media_types"],
        max_prompt_images: h["max_prompt_images"],
        max_prompt_image_size: h["max_prompt_image_size"]
      )
    end
  end

  # Model limits.
  ModelLimits = Struct.new(
    :max_prompt_tokens, :max_context_window_tokens, :vision,
    keyword_init: true
  ) do
    def self.from_hash(h)
      new(
        max_prompt_tokens: h["max_prompt_tokens"],
        max_context_window_tokens: h["max_context_window_tokens"],
        vision: h["vision"] ? ModelVisionLimits.from_hash(h["vision"]) : nil
      )
    end
  end

  # Model capabilities and limits.
  ModelCapabilities = Struct.new(:supports, :limits, keyword_init: true) do
    def self.from_hash(h)
      new(
        supports: ModelSupports.from_hash(h["supports"] || {}),
        limits: ModelLimits.from_hash(h["limits"] || {})
      )
    end
  end

  # Model policy state.
  ModelPolicy = Struct.new(:state, :terms, keyword_init: true) do
    def self.from_hash(h)
      new(state: h["state"], terms: h["terms"])
    end
  end

  # Model billing information.
  ModelBilling = Struct.new(:multiplier, keyword_init: true) do
    def self.from_hash(h)
      new(multiplier: h["multiplier"])
    end
  end

  # Information about an available model.
  ModelInfo = Struct.new(
    :id, :name, :capabilities, :policy, :billing,
    :supported_reasoning_efforts, :default_reasoning_effort,
    keyword_init: true
  ) do
    def self.from_hash(h)
      new(
        id: h["id"],
        name: h["name"],
        capabilities: ModelCapabilities.from_hash(h["capabilities"] || {}),
        policy: h["policy"] ? ModelPolicy.from_hash(h["policy"]) : nil,
        billing: h["billing"] ? ModelBilling.from_hash(h["billing"]) : nil,
        supported_reasoning_efforts: h["supportedReasoningEfforts"],
        default_reasoning_effort: h["defaultReasoningEffort"]
      )
    end
  end

  # Metadata about a session.
  SessionMetadata = Struct.new(
    :session_id, :start_time, :modified_time, :summary, :is_remote,
    keyword_init: true
  ) do
    def self.from_hash(h)
      new(
        session_id: h["sessionId"],
        start_time: h["startTime"],
        modified_time: h["modifiedTime"],
        summary: h["summary"],
        is_remote: h["isRemote"]
      )
    end
  end

  # Session event from the server.
  # Uses an open struct-style approach so new event types are forward-compatible.
  SessionEvent = Struct.new(:id, :timestamp, :parent_id, :ephemeral, :type, :data, keyword_init: true) do
    def self.from_hash(h)
      new(
        id: h["id"],
        timestamp: h["timestamp"],
        parent_id: h["parentId"],
        ephemeral: h["ephemeral"],
        type: h["type"],
        data: h["data"] || {}
      )
    end
  end

  # Session event type constants.
  module SessionEventType
    SESSION_START               = "session.start"
    SESSION_RESUME              = "session.resume"
    SESSION_ERROR               = "session.error"
    SESSION_IDLE                = "session.idle"
    SESSION_INFO                = "session.info"
    SESSION_MODEL_CHANGE        = "session.model_change"
    SESSION_HANDOFF             = "session.handoff"
    SESSION_TRUNCATION          = "session.truncation"
    SESSION_SNAPSHOT_REWIND     = "session.snapshot_rewind"
    SESSION_SHUTDOWN            = "session.shutdown"
    SESSION_USAGE_INFO          = "session.usage_info"
    SESSION_COMPACTION_START    = "session.compaction_start"
    SESSION_COMPACTION_COMPLETE = "session.compaction_complete"
    USER_MESSAGE                = "user.message"
    PENDING_MESSAGES_MODIFIED   = "pending_messages.modified"
    ASSISTANT_TURN_START        = "assistant.turn_start"
    ASSISTANT_INTENT            = "assistant.intent"
    ASSISTANT_REASONING         = "assistant.reasoning"
    ASSISTANT_REASONING_DELTA   = "assistant.reasoning_delta"
    ASSISTANT_MESSAGE           = "assistant.message"
    ASSISTANT_MESSAGE_DELTA     = "assistant.message_delta"
    ASSISTANT_TURN_END          = "assistant.turn_end"
    ASSISTANT_USAGE             = "assistant.usage"
    ABORT                       = "abort"
    TOOL_USER_REQUESTED         = "tool.user_requested"
    TOOL_EXECUTION_START        = "tool.execution_start"
    TOOL_EXECUTION_PARTIAL      = "tool.execution_partial_result"
    TOOL_EXECUTION_PROGRESS     = "tool.execution_progress"
    TOOL_EXECUTION_COMPLETE     = "tool.execution_complete"
    SKILL_INVOKED               = "skill.invoked"
    SUBAGENT_STARTED            = "subagent.started"
    SUBAGENT_COMPLETED          = "subagent.completed"
    SUBAGENT_FAILED             = "subagent.failed"
    SUBAGENT_SELECTED           = "subagent.selected"
    HOOK_START                  = "hook.start"
    HOOK_END                    = "hook.end"
    SYSTEM_MESSAGE              = "system.message"
  end

  # Session lifecycle event types.
  module SessionLifecycleEventType
    SESSION_CREATED    = "session.created"
    SESSION_DELETED    = "session.deleted"
    SESSION_UPDATED    = "session.updated"
    SESSION_FOREGROUND = "session.foreground"
    SESSION_BACKGROUND = "session.background"
  end

  # Session lifecycle event notification.
  SessionLifecycleEvent = Struct.new(:type, :session_id, :metadata, keyword_init: true) do
    def self.from_hash(h)
      new(
        type: h["type"],
        session_id: h["sessionId"],
        metadata: h["metadata"]
      )
    end
  end

  # Session lifecycle event metadata.
  SessionLifecycleMetadata = Struct.new(:start_time, :modified_time, :summary, keyword_init: true) do
    def self.from_hash(h)
      new(
        start_time: h["startTime"],
        modified_time: h["modifiedTime"],
        summary: h["summary"]
      )
    end
  end

  # Foreground session info (TUI+server mode).
  ForegroundSessionInfo = Struct.new(:session_id, :workspace_path, keyword_init: true)

  # Error during client stop.
  StopError = Struct.new(:message, keyword_init: true)

  # Hook configuration for a session. Each value is a callable or nil.
  SessionHooks = Struct.new(
    :on_pre_tool_use, :on_post_tool_use, :on_user_prompt_submitted,
    :on_session_start, :on_session_end, :on_error_occurred,
    keyword_init: true
  ) do
    def any_handler?
      [on_pre_tool_use, on_post_tool_use, on_user_prompt_submitted,
       on_session_start, on_session_end, on_error_occurred].any?
    end
  end

  # Client options.
  ClientOptions = Struct.new(
    :cli_path, :cli_args, :cwd, :port, :use_stdio, :cli_url,
    :log_level, :auto_start, :auto_restart, :env,
    :github_token, :use_logged_in_user,
    keyword_init: true
  )
end
