defmodule Copilot.Types do
  @moduledoc """
  Type definitions for the Copilot SDK.

  All types are represented as structs with typespecs, following the same patterns
  as the Node.js and Python SDKs.
  """

  # ---------------------------------------------------------------------------
  # Session Events
  # ---------------------------------------------------------------------------

  @typedoc """
  A session event from the Copilot CLI server.

  Events are maps with at least `type`, `id`, `timestamp`, and `data` keys.
  The `type` field discriminates the event kind (e.g. `"assistant.message"`,
  `"session.idle"`, `"tool.execution_complete"`, etc.).
  """
  @type session_event :: %{
          required(:type) => String.t(),
          required(:id) => String.t(),
          required(:timestamp) => String.t(),
          optional(:parentId) => String.t() | nil,
          optional(:ephemeral) => boolean(),
          required(:data) => map()
        }

  @typedoc """
  All possible session event type strings.
  """
  @type session_event_type ::
          String.t()

  # ---------------------------------------------------------------------------
  # Tool Result Types
  # ---------------------------------------------------------------------------

  @type tool_result_type :: :success | :failure | :rejected | :denied

  defmodule ToolBinaryResult do
    @moduledoc "Binary result from a tool invocation."
    @type t :: %__MODULE__{
            data: String.t(),
            mime_type: String.t(),
            type: String.t(),
            description: String.t() | nil
          }
    defstruct [:data, :mime_type, :type, :description]
  end

  defmodule ToolResult do
    @moduledoc """
    Structured result of a tool invocation.

    Can also be a plain string, which the SDK wraps into this struct automatically.
    """
    @type t :: %__MODULE__{
            text_result_for_llm: String.t(),
            binary_results_for_llm: [Copilot.Types.ToolBinaryResult.t()] | nil,
            result_type: Copilot.Types.tool_result_type(),
            error: String.t() | nil,
            session_log: String.t() | nil,
            tool_telemetry: map() | nil
          }
    defstruct [
      :text_result_for_llm,
      :binary_results_for_llm,
      :result_type,
      :error,
      :session_log,
      :tool_telemetry
    ]

    @doc "Serialize to the JSON-compatible map expected by the server."
    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = r) do
      m = %{"textResultForLlm" => r.text_result_for_llm, "resultType" => to_string(r.result_type)}
      m = if r.error, do: Map.put(m, "error", r.error), else: m
      m = if r.session_log, do: Map.put(m, "sessionLog", r.session_log), else: m
      m = if r.tool_telemetry, do: Map.put(m, "toolTelemetry", r.tool_telemetry), else: m

      m =
        if r.binary_results_for_llm do
          Map.put(
            m,
            "binaryResultsForLlm",
            Enum.map(r.binary_results_for_llm, fn b ->
              %{
                "data" => b.data,
                "mimeType" => b.mime_type,
                "type" => b.type,
                "description" => b.description
              }
            end)
          )
        else
          m
        end

      m
    end
  end

  # ---------------------------------------------------------------------------
  # Tool Invocation / Definition
  # ---------------------------------------------------------------------------

  defmodule ToolInvocation do
    @moduledoc "Context passed to a tool handler when invoked."
    @type t :: %__MODULE__{
            session_id: String.t(),
            tool_call_id: String.t(),
            tool_name: String.t(),
            arguments: any()
          }
    defstruct [:session_id, :tool_call_id, :tool_name, :arguments]
  end

  @typedoc """
  A tool handler function.

  Receives the parsed arguments and a `ToolInvocation` struct. Must return
  a `ToolResult` struct, a plain string, or any term that will be
  JSON-encoded as a success result.
  """
  @type tool_handler :: (any(), ToolInvocation.t() -> any())

  defmodule Tool do
    @moduledoc "Definition of a tool exposed to the Copilot CLI."
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            parameters: map() | nil,
            handler: Copilot.Types.tool_handler()
          }
    defstruct [:name, :description, :parameters, :handler]

    @doc "Serialize to the map sent in session.create / session.resume."
    @spec to_wire(t()) :: map()
    def to_wire(%__MODULE__{} = tool) do
      m = %{"name" => tool.name}
      m = if tool.description, do: Map.put(m, "description", tool.description), else: m
      m = if tool.parameters, do: Map.put(m, "parameters", tool.parameters), else: m
      m
    end
  end

  # ---------------------------------------------------------------------------
  # System Message Configuration
  # ---------------------------------------------------------------------------

  defmodule SystemMessageAppendConfig do
    @moduledoc "Append mode: SDK foundation plus optional appended content."
    @type t :: %__MODULE__{mode: :append, content: String.t() | nil}
    defstruct mode: :append, content: nil

    def to_map(%__MODULE__{} = c) do
      m = %{"mode" => "append"}
      if c.content, do: Map.put(m, "content", c.content), else: m
    end
  end

  defmodule SystemMessageReplaceConfig do
    @moduledoc "Replace mode: caller provides entire system message."
    @type t :: %__MODULE__{mode: :replace, content: String.t()}
    defstruct mode: :replace, content: ""

    def to_map(%__MODULE__{} = c) do
      %{"mode" => "replace", "content" => c.content}
    end
  end

  @type system_message_config :: SystemMessageAppendConfig.t() | SystemMessageReplaceConfig.t()

  # ---------------------------------------------------------------------------
  # Permission Types
  # ---------------------------------------------------------------------------

  defmodule PermissionRequest do
    @moduledoc "Permission request from the server."
    @type t :: %__MODULE__{
            kind: String.t(),
            tool_call_id: String.t() | nil,
            extra: map()
          }
    defstruct [:kind, :tool_call_id, extra: %{}]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        kind: m["kind"],
        tool_call_id: m["toolCallId"],
        extra: Map.drop(m, ["kind", "toolCallId"])
      }
    end
  end

  defmodule PermissionRequestResult do
    @moduledoc "Result of a permission decision."
    @type kind ::
            :approved
            | :denied_by_rules
            | :denied_no_approval_rule_and_could_not_request_from_user
            | :denied_interactively_by_user

    @type t :: %__MODULE__{kind: kind(), rules: [any()] | nil}
    defstruct [:kind, :rules]

    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = r) do
      kind_str =
        case r.kind do
          :approved -> "approved"
          :denied_by_rules -> "denied-by-rules"
          :denied_no_approval_rule_and_could_not_request_from_user -> "denied-no-approval-rule-and-could-not-request-from-user"
          :denied_interactively_by_user -> "denied-interactively-by-user"
          other when is_binary(other) -> other
        end

      m = %{"kind" => kind_str}
      if r.rules, do: Map.put(m, "rules", r.rules), else: m
    end
  end

  @typedoc "Permission handler callback."
  @type permission_handler ::
          (PermissionRequest.t(), %{session_id: String.t()} -> PermissionRequestResult.t())

  # ---------------------------------------------------------------------------
  # User Input Types
  # ---------------------------------------------------------------------------

  defmodule UserInputRequest do
    @moduledoc "Request for user input from the agent (enables ask_user tool)."
    @type t :: %__MODULE__{
            question: String.t(),
            choices: [String.t()] | nil,
            allow_freeform: boolean()
          }
    defstruct [:question, :choices, allow_freeform: true]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        question: m["question"],
        choices: m["choices"],
        allow_freeform: Map.get(m, "allowFreeform", true)
      }
    end
  end

  defmodule UserInputResponse do
    @moduledoc "Response to a user input request."
    @type t :: %__MODULE__{answer: String.t(), was_freeform: boolean()}
    defstruct [:answer, :was_freeform]

    def to_map(%__MODULE__{} = r) do
      %{"answer" => r.answer, "wasFreeform" => r.was_freeform}
    end
  end

  @typedoc "User input handler callback."
  @type user_input_handler ::
          (UserInputRequest.t(), %{session_id: String.t()} -> UserInputResponse.t())

  # ---------------------------------------------------------------------------
  # Hook Types
  # ---------------------------------------------------------------------------

  defmodule SessionHooks do
    @moduledoc """
    Configuration for session hooks.

    Each field is an optional callback that the server invokes at the
    corresponding lifecycle point.
    """
    @type t :: %__MODULE__{
            on_pre_tool_use: (map(), map() -> map() | nil) | nil,
            on_post_tool_use: (map(), map() -> map() | nil) | nil,
            on_user_prompt_submitted: (map(), map() -> map() | nil) | nil,
            on_session_start: (map(), map() -> map() | nil) | nil,
            on_session_end: (map(), map() -> map() | nil) | nil,
            on_error_occurred: (map(), map() -> map() | nil) | nil
          }
    defstruct [
      :on_pre_tool_use,
      :on_post_tool_use,
      :on_user_prompt_submitted,
      :on_session_start,
      :on_session_end,
      :on_error_occurred
    ]

    @doc "Returns true if any hook handler is set."
    @spec any_set?(t()) :: boolean()
    def any_set?(%__MODULE__{} = h) do
      h.on_pre_tool_use != nil or
        h.on_post_tool_use != nil or
        h.on_user_prompt_submitted != nil or
        h.on_session_start != nil or
        h.on_session_end != nil or
        h.on_error_occurred != nil
    end

    @doc "Look up a handler by hook type string."
    @spec handler_for(t(), String.t()) :: (map(), map() -> map() | nil) | nil
    def handler_for(%__MODULE__{} = h, hook_type) do
      case hook_type do
        "preToolUse" -> h.on_pre_tool_use
        "postToolUse" -> h.on_post_tool_use
        "userPromptSubmitted" -> h.on_user_prompt_submitted
        "sessionStart" -> h.on_session_start
        "sessionEnd" -> h.on_session_end
        "errorOccurred" -> h.on_error_occurred
        _ -> nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # MCP Server Configuration
  # ---------------------------------------------------------------------------

  defmodule MCPLocalServerConfig do
    @moduledoc "Configuration for a local/stdio MCP server."
    @type t :: %__MODULE__{
            tools: [String.t()],
            type: String.t() | nil,
            timeout: non_neg_integer() | nil,
            command: String.t(),
            args: [String.t()],
            env: map() | nil,
            cwd: String.t() | nil
          }
    defstruct [:command, :args, :tools, :type, :timeout, :env, :cwd]
  end

  defmodule MCPRemoteServerConfig do
    @moduledoc "Configuration for a remote MCP server (HTTP or SSE)."
    @type t :: %__MODULE__{
            tools: [String.t()],
            type: String.t(),
            timeout: non_neg_integer() | nil,
            url: String.t(),
            headers: map() | nil
          }
    defstruct [:url, :tools, :type, :timeout, :headers]
  end

  @type mcp_server_config :: MCPLocalServerConfig.t() | MCPRemoteServerConfig.t()

  # ---------------------------------------------------------------------------
  # Custom Agent Configuration
  # ---------------------------------------------------------------------------

  defmodule CustomAgentConfig do
    @moduledoc "Configuration for a custom agent."
    @type t :: %__MODULE__{
            name: String.t(),
            display_name: String.t() | nil,
            description: String.t() | nil,
            tools: [String.t()] | nil,
            prompt: String.t(),
            mcp_servers: map() | nil,
            infer: boolean() | nil
          }
    defstruct [:name, :display_name, :description, :tools, :prompt, :mcp_servers, :infer]
  end

  # ---------------------------------------------------------------------------
  # Infinite Session Configuration
  # ---------------------------------------------------------------------------

  defmodule InfiniteSessionConfig do
    @moduledoc "Configuration for infinite sessions with automatic context compaction."
    @type t :: %__MODULE__{
            enabled: boolean() | nil,
            background_compaction_threshold: float() | nil,
            buffer_exhaustion_threshold: float() | nil
          }
    defstruct [:enabled, :background_compaction_threshold, :buffer_exhaustion_threshold]
  end

  # ---------------------------------------------------------------------------
  # Provider Configuration
  # ---------------------------------------------------------------------------

  defmodule ProviderConfig do
    @moduledoc "Configuration for a custom API provider (BYOK)."
    @type t :: %__MODULE__{
            type: String.t() | nil,
            wire_api: String.t() | nil,
            base_url: String.t(),
            api_key: String.t() | nil,
            bearer_token: String.t() | nil,
            azure: map() | nil
          }
    defstruct [:type, :wire_api, :base_url, :api_key, :bearer_token, :azure]
  end

  # ---------------------------------------------------------------------------
  # Session Configuration
  # ---------------------------------------------------------------------------

  defmodule SessionConfig do
    @moduledoc "Configuration for creating a session."
    @type t :: %__MODULE__{
            session_id: String.t() | nil,
            model: String.t() | nil,
            reasoning_effort: String.t() | nil,
            config_dir: String.t() | nil,
            tools: [Copilot.Types.Tool.t()] | nil,
            system_message: Copilot.Types.system_message_config() | nil,
            available_tools: [String.t()] | nil,
            excluded_tools: [String.t()] | nil,
            provider: Copilot.Types.ProviderConfig.t() | nil,
            on_permission_request: Copilot.Types.permission_handler() | nil,
            on_user_input_request: Copilot.Types.user_input_handler() | nil,
            hooks: Copilot.Types.SessionHooks.t() | nil,
            working_directory: String.t() | nil,
            streaming: boolean() | nil,
            mcp_servers: map() | nil,
            custom_agents: [Copilot.Types.CustomAgentConfig.t()] | nil,
            skill_directories: [String.t()] | nil,
            disabled_skills: [String.t()] | nil,
            infinite_sessions: Copilot.Types.InfiniteSessionConfig.t() | nil
          }
    defstruct [
      :session_id,
      :model,
      :reasoning_effort,
      :config_dir,
      :tools,
      :system_message,
      :available_tools,
      :excluded_tools,
      :provider,
      :on_permission_request,
      :on_user_input_request,
      :hooks,
      :working_directory,
      :streaming,
      :mcp_servers,
      :custom_agents,
      :skill_directories,
      :disabled_skills,
      :infinite_sessions
    ]
  end

  defmodule ResumeSessionConfig do
    @moduledoc "Configuration for resuming an existing session."
    @type t :: %__MODULE__{
            model: String.t() | nil,
            reasoning_effort: String.t() | nil,
            tools: [Copilot.Types.Tool.t()] | nil,
            system_message: Copilot.Types.system_message_config() | nil,
            available_tools: [String.t()] | nil,
            excluded_tools: [String.t()] | nil,
            provider: Copilot.Types.ProviderConfig.t() | nil,
            on_permission_request: Copilot.Types.permission_handler() | nil,
            on_user_input_request: Copilot.Types.user_input_handler() | nil,
            hooks: Copilot.Types.SessionHooks.t() | nil,
            working_directory: String.t() | nil,
            config_dir: String.t() | nil,
            streaming: boolean() | nil,
            mcp_servers: map() | nil,
            custom_agents: [Copilot.Types.CustomAgentConfig.t()] | nil,
            skill_directories: [String.t()] | nil,
            disabled_skills: [String.t()] | nil,
            infinite_sessions: Copilot.Types.InfiniteSessionConfig.t() | nil,
            disable_resume: boolean() | nil
          }
    defstruct [
      :model,
      :reasoning_effort,
      :tools,
      :system_message,
      :available_tools,
      :excluded_tools,
      :provider,
      :on_permission_request,
      :on_user_input_request,
      :hooks,
      :working_directory,
      :config_dir,
      :streaming,
      :mcp_servers,
      :custom_agents,
      :skill_directories,
      :disabled_skills,
      :infinite_sessions,
      :disable_resume
    ]
  end

  # ---------------------------------------------------------------------------
  # Image Generation / Response Format Types
  # ---------------------------------------------------------------------------

  @typedoc "The response format for a message."
  @type response_format :: :text | :image | :json_object

  @typedoc "Options for image generation."
  @type image_options :: %{
          optional(:size) => String.t(),
          optional(:quality) => String.t(),
          optional(:style) => String.t()
        }

  @typedoc "Image data returned by the assistant."
  @type assistant_image_data :: %{
          format: String.t(),
          base64: String.t(),
          url: String.t() | nil,
          revised_prompt: String.t() | nil,
          width: integer(),
          height: integer()
        }

  @typedoc "A content block in an assistant response (text or image)."
  @type content_block ::
          %{type: :text, text: String.t()}
          | %{type: :image, image: assistant_image_data()}

  @doc "Convert response format atom to JSON string."
  def response_format_to_string(:text), do: "text"
  def response_format_to_string(:image), do: "image"
  def response_format_to_string(:json_object), do: "json_object"

  # ---------------------------------------------------------------------------
  # Message Options
  # ---------------------------------------------------------------------------

  defmodule MessageOptions do
    @moduledoc "Options for sending a message to a session."
    @type t :: %__MODULE__{
            prompt: String.t(),
            attachments: [map()] | nil,
            mode: String.t() | nil,
            response_format: Copilot.Types.response_format() | nil,
            image_options: Copilot.Types.image_options() | nil
          }
    defstruct [:prompt, :attachments, :mode, :response_format, :image_options]
  end

  # ---------------------------------------------------------------------------
  # Client Options
  # ---------------------------------------------------------------------------

  defmodule CopilotClientOptions do
    @moduledoc "Options for creating a CopilotClient."
    @type t :: %__MODULE__{
            cli_path: String.t() | nil,
            cli_args: [String.t()],
            cwd: String.t() | nil,
            log_level: String.t(),
            auto_start: boolean(),
            auto_restart: boolean(),
            env: [{String.t(), String.t()}] | nil,
            github_token: String.t() | nil,
            use_logged_in_user: boolean() | nil
          }
    defstruct [
      cli_path: nil,
      cli_args: [],
      cwd: nil,
      log_level: "info",
      auto_start: true,
      auto_restart: true,
      env: nil,
      github_token: nil,
      use_logged_in_user: nil
    ]
  end

  # ---------------------------------------------------------------------------
  # Ping / Status / Auth Responses
  # ---------------------------------------------------------------------------

  defmodule PingResponse do
    @moduledoc "Response from ping."
    @type t :: %__MODULE__{
            message: String.t(),
            timestamp: integer(),
            protocol_version: integer() | nil
          }
    defstruct [:message, :timestamp, :protocol_version]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        message: m["message"],
        timestamp: m["timestamp"],
        protocol_version: m["protocolVersion"]
      }
    end
  end

  defmodule GetStatusResponse do
    @moduledoc "Response from status.get."
    @type t :: %__MODULE__{version: String.t(), protocol_version: integer()}
    defstruct [:version, :protocol_version]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        version: m["version"],
        protocol_version: m["protocolVersion"]
      }
    end
  end

  defmodule GetAuthStatusResponse do
    @moduledoc "Response from auth.getStatus."
    @type t :: %__MODULE__{
            is_authenticated: boolean(),
            auth_type: String.t() | nil,
            host: String.t() | nil,
            login: String.t() | nil,
            status_message: String.t() | nil
          }
    defstruct [:is_authenticated, :auth_type, :host, :login, :status_message]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        is_authenticated: m["isAuthenticated"],
        auth_type: m["authType"],
        host: m["host"],
        login: m["login"],
        status_message: m["statusMessage"]
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Model Types
  # ---------------------------------------------------------------------------

  defmodule ModelVisionLimits do
    @moduledoc "Vision-specific limits."
    @type t :: %__MODULE__{
            supported_media_types: [String.t()] | nil,
            max_prompt_images: integer() | nil,
            max_prompt_image_size: integer() | nil
          }
    defstruct [:supported_media_types, :max_prompt_images, :max_prompt_image_size]

    def from_map(nil), do: nil

    def from_map(m) when is_map(m) do
      %__MODULE__{
        supported_media_types: m["supported_media_types"],
        max_prompt_images: m["max_prompt_images"],
        max_prompt_image_size: m["max_prompt_image_size"]
      }
    end
  end

  defmodule ModelLimits do
    @moduledoc "Model limits."
    @type t :: %__MODULE__{
            max_prompt_tokens: integer() | nil,
            max_context_window_tokens: integer() | nil,
            vision: ModelVisionLimits.t() | nil
          }
    defstruct [:max_prompt_tokens, :max_context_window_tokens, :vision]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        max_prompt_tokens: m["max_prompt_tokens"],
        max_context_window_tokens: m["max_context_window_tokens"],
        vision: ModelVisionLimits.from_map(m["vision"])
      }
    end
  end

  defmodule ModelSupports do
    @moduledoc "Model support flags."
    @type t :: %__MODULE__{vision: boolean(), reasoning_effort: boolean()}
    defstruct [:vision, reasoning_effort: false]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        vision: m["vision"],
        reasoning_effort: Map.get(m, "reasoningEffort", false)
      }
    end
  end

  defmodule ModelCapabilities do
    @moduledoc "Model capabilities and limits."
    @type t :: %__MODULE__{supports: ModelSupports.t(), limits: ModelLimits.t()}
    defstruct [:supports, :limits]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        supports: ModelSupports.from_map(m["supports"]),
        limits: ModelLimits.from_map(m["limits"])
      }
    end
  end

  defmodule ModelPolicy do
    @moduledoc "Model policy state."
    @type t :: %__MODULE__{state: String.t(), terms: String.t()}
    defstruct [:state, :terms]

    def from_map(nil), do: nil

    def from_map(m) when is_map(m) do
      %__MODULE__{state: m["state"], terms: m["terms"]}
    end
  end

  defmodule ModelBilling do
    @moduledoc "Model billing information."
    @type t :: %__MODULE__{multiplier: float()}
    defstruct [:multiplier]

    def from_map(nil), do: nil
    def from_map(m) when is_map(m), do: %__MODULE__{multiplier: m["multiplier"]}
  end

  defmodule ModelInfo do
    @moduledoc "Information about an available model."
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            capabilities: ModelCapabilities.t(),
            policy: ModelPolicy.t() | nil,
            billing: ModelBilling.t() | nil,
            supported_reasoning_efforts: [String.t()] | nil,
            default_reasoning_effort: String.t() | nil
          }
    defstruct [
      :id,
      :name,
      :capabilities,
      :policy,
      :billing,
      :supported_reasoning_efforts,
      :default_reasoning_effort
    ]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        id: m["id"],
        name: m["name"],
        capabilities: ModelCapabilities.from_map(m["capabilities"]),
        policy: ModelPolicy.from_map(m["policy"]),
        billing: ModelBilling.from_map(m["billing"]),
        supported_reasoning_efforts: m["supportedReasoningEfforts"],
        default_reasoning_effort: m["defaultReasoningEffort"]
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Session Metadata
  # ---------------------------------------------------------------------------

  defmodule SessionMetadata do
    @moduledoc "Metadata about a session."
    @type t :: %__MODULE__{
            session_id: String.t(),
            start_time: String.t(),
            modified_time: String.t(),
            is_remote: boolean(),
            summary: String.t() | nil
          }
    defstruct [:session_id, :start_time, :modified_time, :is_remote, :summary]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        session_id: m["sessionId"],
        start_time: m["startTime"],
        modified_time: m["modifiedTime"],
        is_remote: m["isRemote"],
        summary: m["summary"]
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Session Lifecycle Types
  # ---------------------------------------------------------------------------

  defmodule SessionLifecycleEvent do
    @moduledoc "Session lifecycle event notification."
    @type t :: %__MODULE__{
            type: String.t(),
            session_id: String.t(),
            metadata: map() | nil
          }
    defstruct [:type, :session_id, :metadata]

    def from_map(m) when is_map(m) do
      %__MODULE__{
        type: m["type"],
        session_id: m["sessionId"],
        metadata: m["metadata"]
      }
    end
  end
end
