defmodule Copilot.Client do
  @moduledoc """
  Main client for interacting with the Copilot CLI.

  `Copilot.Client` is a GenServer that manages the lifecycle of the CLI
  subprocess, maintains a JSON-RPC connection over stdio, and provides
  session management (create, resume, delete, list).

  ## Example

      {:ok, client} = Copilot.Client.start_link()
      {:ok, session} = Copilot.Client.create_session(client, %Copilot.Types.SessionConfig{})
      :ok = Copilot.Session.send(session, %Copilot.Types.MessageOptions{prompt: "Hello!"})
      Copilot.Session.destroy(session)
      Copilot.Client.stop(client)
  """

  use GenServer
  require Logger

  alias Copilot.JsonRpcClient
  alias Copilot.SdkProtocolVersion
  alias Copilot.Session
  alias Copilot.Types
  alias Copilot.Types.{
    CopilotClientOptions,
    ModelInfo,
    PingResponse,
    GetStatusResponse,
    GetAuthStatusResponse,
    SessionConfig,
    ResumeSessionConfig,
    SessionMetadata,
    Tool,
    ToolResult,
    ToolInvocation,
    PermissionRequest,
    PermissionRequestResult,
    UserInputRequest,
    UserInputResponse,
    SessionHooks
  }

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            options: CopilotClientOptions.t(),
            port: port() | nil,
            rpc: pid() | nil,
            sessions: %{String.t() => pid()},
            connection_state: :disconnected | :connecting | :connected | :error,
            models_cache: [ModelInfo.t()] | nil,
            lifecycle_handlers: [fun()]
          }
    defstruct options: %CopilotClientOptions{},
              port: nil,
              rpc: nil,
              sessions: %{},
              connection_state: :disconnected,
              models_cache: nil,
              lifecycle_handlers: []
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the Copilot client GenServer.

  ## Options

  All fields from `Copilot.Types.CopilotClientOptions` are supported.
  Pass `name: <name>` in `gen_opts` to register the process.
  """
  @spec start_link(CopilotClientOptions.t(), keyword()) :: GenServer.on_start()
  def start_link(options \\ %CopilotClientOptions{}, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, options, gen_opts)
  end

  @doc "Start the CLI server and establish a JSON-RPC connection."
  @spec start(GenServer.server()) :: :ok | {:error, any()}
  def start(client) do
    GenServer.call(client, :start, 30_000)
  end

  @doc "Stop the CLI server and clean up all sessions."
  @spec stop(GenServer.server()) :: :ok
  def stop(client) do
    GenServer.call(client, :stop, 15_000)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Send a ping to the server.

  Returns `{:ok, %PingResponse{}}` or `{:error, reason}`.
  """
  @spec ping(GenServer.server(), String.t() | nil) :: {:ok, PingResponse.t()} | {:error, any()}
  def ping(client, message \\ nil) do
    GenServer.call(client, {:ping, message}, 10_000)
  end

  @doc "Get CLI status including version and protocol information."
  @spec get_status(GenServer.server()) :: {:ok, GetStatusResponse.t()} | {:error, any()}
  def get_status(client) do
    GenServer.call(client, :get_status, 10_000)
  end

  @doc "Get current authentication status."
  @spec get_auth_status(GenServer.server()) ::
          {:ok, GetAuthStatusResponse.t()} | {:error, any()}
  def get_auth_status(client) do
    GenServer.call(client, :get_auth_status, 10_000)
  end

  @doc "List available models. Results are cached after the first call."
  @spec list_models(GenServer.server()) :: {:ok, [ModelInfo.t()]} | {:error, any()}
  def list_models(client) do
    GenServer.call(client, :list_models, 30_000)
  end

  @doc """
  Create a new conversation session.

  Returns `{:ok, session_pid}` where `session_pid` is a `Copilot.Session` GenServer.
  """
  @spec create_session(GenServer.server(), SessionConfig.t()) ::
          {:ok, pid()} | {:error, any()}
  def create_session(client, config \\ %SessionConfig{}) do
    GenServer.call(client, {:create_session, config}, 30_000)
  end

  @doc """
  Resume an existing session by ID.

  Returns `{:ok, session_pid}`.
  """
  @spec resume_session(GenServer.server(), String.t(), ResumeSessionConfig.t()) ::
          {:ok, pid()} | {:error, any()}
  def resume_session(client, session_id, config \\ %ResumeSessionConfig{}) do
    GenServer.call(client, {:resume_session, session_id, config}, 30_000)
  end

  @doc "Delete a session and its data from disk."
  @spec delete_session(GenServer.server(), String.t()) :: :ok | {:error, any()}
  def delete_session(client, session_id) do
    GenServer.call(client, {:delete_session, session_id}, 10_000)
  end

  @doc "List all available sessions."
  @spec list_sessions(GenServer.server()) :: {:ok, [SessionMetadata.t()]} | {:error, any()}
  def list_sessions(client) do
    GenServer.call(client, :list_sessions, 10_000)
  end

  @doc "Get the last session ID."
  @spec get_last_session_id(GenServer.server()) :: {:ok, String.t() | nil} | {:error, any()}
  def get_last_session_id(client) do
    GenServer.call(client, :get_last_session_id, 10_000)
  end

  @doc "Get the current connection state."
  @spec get_state(GenServer.server()) :: :disconnected | :connecting | :connected | :error
  def get_state(client) do
    GenServer.call(client, :get_state)
  end

  @doc """
  Subscribe to session lifecycle events.

  Returns a reference that can be used with `unsubscribe_lifecycle/2`.
  """
  @spec subscribe_lifecycle(GenServer.server(), (Types.SessionLifecycleEvent.t() -> any())) ::
          reference()
  def subscribe_lifecycle(client, handler) do
    GenServer.call(client, {:subscribe_lifecycle, handler})
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(options) do
    {:ok, %State{options: options}}
  end

  @impl true
  def handle_call(:start, _from, %State{connection_state: :connected} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:start, _from, state) do
    case do_start(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | connection_state: :error}}
    end
  end

  def handle_call(:stop, _from, state) do
    new_state = do_stop(state)
    {:reply, :ok, new_state}
  end

  def handle_call({:ping, message}, _from, state) do
    state = maybe_auto_start(state)

    case JsonRpcClient.request(state.rpc, "ping", %{"message" => message}) do
      {:ok, result} -> {:reply, {:ok, PingResponse.from_map(result)}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:get_status, _from, state) do
    state = maybe_auto_start(state)

    case JsonRpcClient.request(state.rpc, "status.get", %{}) do
      {:ok, result} -> {:reply, {:ok, GetStatusResponse.from_map(result)}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:get_auth_status, _from, state) do
    state = maybe_auto_start(state)

    case JsonRpcClient.request(state.rpc, "auth.getStatus", %{}) do
      {:ok, result} -> {:reply, {:ok, GetAuthStatusResponse.from_map(result)}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:list_models, _from, %State{models_cache: cache} = state)
      when not is_nil(cache) do
    {:reply, {:ok, cache}, state}
  end

  def handle_call(:list_models, _from, state) do
    state = maybe_auto_start(state)

    case JsonRpcClient.request(state.rpc, "models.list", %{}, 30_000) do
      {:ok, %{"models" => models_raw}} ->
        models = Enum.map(models_raw, &ModelInfo.from_map/1)
        {:reply, {:ok, models}, %{state | models_cache: models}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:create_session, config}, _from, state) do
    state = maybe_auto_start(state)

    params = build_create_params(config)

    case JsonRpcClient.request(state.rpc, "session.create", params, 30_000) do
      {:ok, %{"sessionId" => session_id} = resp} ->
        workspace_path = resp["workspacePath"]

        {:ok, session_pid} =
          Session.start_link(
            session_id: session_id,
            rpc: state.rpc,
            workspace_path: workspace_path,
            tools: config.tools,
            on_permission_request: config.on_permission_request,
            on_user_input_request: config.on_user_input_request,
            hooks: config.hooks
          )

        sessions = Map.put(state.sessions, session_id, session_pid)
        {:reply, {:ok, session_pid}, %{state | sessions: sessions}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:resume_session, session_id, config}, _from, state) do
    state = maybe_auto_start(state)

    params = build_resume_params(session_id, config)

    case JsonRpcClient.request(state.rpc, "session.resume", params, 30_000) do
      {:ok, %{"sessionId" => sid} = resp} ->
        workspace_path = resp["workspacePath"]

        {:ok, session_pid} =
          Session.start_link(
            session_id: sid,
            rpc: state.rpc,
            workspace_path: workspace_path,
            tools: config.tools,
            on_permission_request: config.on_permission_request,
            on_user_input_request: config.on_user_input_request,
            hooks: config.hooks
          )

        sessions = Map.put(state.sessions, sid, session_pid)
        {:reply, {:ok, session_pid}, %{state | sessions: sessions}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    case JsonRpcClient.request(state.rpc, "session.delete", %{"sessionId" => session_id}) do
      {:ok, %{"success" => true}} ->
        sessions = Map.delete(state.sessions, session_id)
        {:reply, :ok, %{state | sessions: sessions}}

      {:ok, %{"success" => false, "error" => err}} ->
        {:reply, {:error, err}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:list_sessions, _from, state) do
    state = maybe_auto_start(state)

    case JsonRpcClient.request(state.rpc, "session.list", %{}) do
      {:ok, %{"sessions" => raw}} ->
        sessions = Enum.map(raw, &SessionMetadata.from_map/1)
        {:reply, {:ok, sessions}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:get_last_session_id, _from, state) do
    state = maybe_auto_start(state)

    case JsonRpcClient.request(state.rpc, "session.getLastId", %{}) do
      {:ok, %{"sessionId" => sid}} -> {:reply, {:ok, sid}, state}
      {:ok, _} -> {:reply, {:ok, nil}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.connection_state, state}
  end

  def handle_call({:subscribe_lifecycle, handler}, _from, state) do
    ref = make_ref()
    handlers = [{ref, handler} | state.lifecycle_handlers]
    {:reply, ref, %{state | lifecycle_handlers: handlers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal: Start / Stop
  # ---------------------------------------------------------------------------

  defp do_start(state) do
    state = %{state | connection_state: :connecting}
    opts = state.options

    cli_path = opts.cli_path || find_cli_path()
    cwd = opts.cwd || File.cwd!()
    log_level = opts.log_level || "info"

    args =
      (opts.cli_args || []) ++
        [
          "--headless",
          "--no-auto-update",
          "--log-level",
          log_level,
          "--stdio"
        ]

    args =
      if opts.github_token do
        args ++ ["--auth-token-env", "COPILOT_SDK_AUTH_TOKEN"]
      else
        args
      end

    use_logged_in =
      case opts.use_logged_in_user do
        nil -> if opts.github_token, do: false, else: true
        val -> val
      end

    args = if use_logged_in, do: args, else: args ++ ["--no-auto-login"]

    env =
      if opts.github_token do
        [{"COPILOT_SDK_AUTH_TOKEN", opts.github_token} | opts.env || []]
      else
        opts.env || []
      end

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, args},
      {:cd, String.to_charlist(cwd)},
      {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
    ]

    try do
      port = Port.open({:spawn_executable, String.to_charlist(cli_path)}, port_opts)
      {:ok, rpc} = JsonRpcClient.start_link(port)

      # Register request handlers for tool.call, permission.request, etc.
      JsonRpcClient.set_request_handler(rpc, "tool.call", fn params ->
        handle_tool_call(state.sessions, params)
      end)

      # We need to update state first so we can reference sessions in handlers.
      # Handlers will be re-registered after sessions map is populated.
      new_state = %{state | port: port, rpc: rpc, connection_state: :connected}

      # Register all server-to-client request handlers
      register_rpc_handlers(rpc, new_state)

      # Register notification handler
      JsonRpcClient.set_notification_handler(rpc, fn method, params ->
        handle_notification(method, params, new_state)
      end)

      # Verify protocol version
      case verify_protocol_version(rpc) do
        :ok ->
          {:ok, new_state}

        {:error, reason} ->
          do_stop(new_state)
          {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp do_stop(state) do
    # Destroy all sessions
    for {_id, session_pid} <- state.sessions do
      try do
        Session.destroy(session_pid)
      rescue
        _ -> :ok
      end
    end

    # Stop RPC client
    if state.rpc do
      try do
        JsonRpcClient.stop(state.rpc)
      rescue
        _ -> :ok
      end
    end

    # Close port
    if state.port do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    %{state | port: nil, rpc: nil, sessions: %{}, connection_state: :disconnected, models_cache: nil}
  end

  defp maybe_auto_start(%State{connection_state: :connected} = state), do: state

  defp maybe_auto_start(%State{options: %{auto_start: true}} = state) do
    case do_start(state) do
      {:ok, new_state} -> new_state
      {:error, _} -> state
    end
  end

  defp maybe_auto_start(state), do: state

  # ---------------------------------------------------------------------------
  # Internal: Protocol version verification
  # ---------------------------------------------------------------------------

  defp verify_protocol_version(rpc) do
    expected = SdkProtocolVersion.get()

    case JsonRpcClient.request(rpc, "ping", %{"message" => "version-check"}) do
      {:ok, %{"protocolVersion" => ^expected}} ->
        :ok

      {:ok, %{"protocolVersion" => server_version}} ->
        {:error,
         "SDK protocol version mismatch: SDK expects version #{expected}, " <>
           "but server reports version #{server_version}. " <>
           "Please update your SDK or server to ensure compatibility."}

      {:ok, _} ->
        {:error,
         "SDK protocol version mismatch: SDK expects version #{expected}, " <>
           "but server does not report a protocol version. " <>
           "Please update your server to ensure compatibility."}

      {:error, reason} ->
        {:error, "Failed to verify protocol version: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: RPC request handlers
  # ---------------------------------------------------------------------------

  defp register_rpc_handlers(rpc, _state) do
    # We use a closure over `self()` so the handler can ask the GenServer
    # for the current sessions map (which changes over time).
    client_pid = self()

    JsonRpcClient.set_request_handler(rpc, "tool.call", fn params ->
      sessions = get_sessions(client_pid)
      handle_tool_call(sessions, params)
    end)

    JsonRpcClient.set_request_handler(rpc, "permission.request", fn params ->
      sessions = get_sessions(client_pid)
      handle_permission_request(sessions, params)
    end)

    JsonRpcClient.set_request_handler(rpc, "userInput.request", fn params ->
      sessions = get_sessions(client_pid)
      handle_user_input_request(sessions, params)
    end)

    JsonRpcClient.set_request_handler(rpc, "hooks.invoke", fn params ->
      sessions = get_sessions(client_pid)
      handle_hooks_invoke(sessions, params)
    end)
  end

  defp get_sessions(client_pid) do
    try do
      GenServer.call(client_pid, :get_sessions, 5_000)
    catch
      _, _ -> %{}
    end
  end

  @impl true
  def handle_call(:get_sessions, _from, state) do
    {:reply, state.sessions, state}
  end

  # ---------------------------------------------------------------------------
  # Internal: Tool call handling
  # ---------------------------------------------------------------------------

  defp handle_tool_call(sessions, params) do
    session_id = params["sessionId"]
    tool_name = params["toolName"]
    tool_call_id = params["toolCallId"]
    arguments = params["arguments"]

    case Map.get(sessions, session_id) do
      nil ->
        %{
          "result" => %{
            "textResultForLlm" => "Unknown session #{session_id}",
            "resultType" => "failure",
            "error" => "unknown session"
          }
        }

      session_pid ->
        invocation = %ToolInvocation{
          session_id: session_id,
          tool_call_id: tool_call_id,
          tool_name: tool_name,
          arguments: arguments
        }

        case Session.handle_tool_call(session_pid, tool_name, arguments, invocation) do
          {:ok, result} -> %{"result" => result}
          {:error, msg} ->
            %{
              "result" => %{
                "textResultForLlm" =>
                  "Invoking this tool produced an error. Detailed information is not available.",
                "resultType" => "failure",
                "error" => msg,
                "toolTelemetry" => %{}
              }
            }
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Permission request handling
  # ---------------------------------------------------------------------------

  defp handle_permission_request(sessions, params) do
    session_id = params["sessionId"]
    perm_request = params["permissionRequest"]

    case Map.get(sessions, session_id) do
      nil ->
        %{"result" => %{"kind" => "denied-no-approval-rule-and-could-not-request-from-user"}}

      session_pid ->
        case Session.handle_permission_request(session_pid, perm_request) do
          {:ok, result} -> %{"result" => result}
          {:error, _} ->
            %{"result" => %{"kind" => "denied-no-approval-rule-and-could-not-request-from-user"}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: User input request handling
  # ---------------------------------------------------------------------------

  defp handle_user_input_request(sessions, params) do
    session_id = params["sessionId"]

    case Map.get(sessions, session_id) do
      nil ->
        raise "Session not found: #{session_id}"

      session_pid ->
        request = UserInputRequest.from_map(params)

        case Session.handle_user_input_request(session_pid, request) do
          {:ok, response} -> response
          {:error, reason} -> raise reason
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Hooks invocation
  # ---------------------------------------------------------------------------

  defp handle_hooks_invoke(sessions, params) do
    session_id = params["sessionId"]
    hook_type = params["hookType"]
    input = params["input"]

    case Map.get(sessions, session_id) do
      nil ->
        %{"output" => nil}

      session_pid ->
        case Session.handle_hooks_invoke(session_pid, hook_type, input) do
          {:ok, output} -> %{"output" => output}
          {:error, _} -> %{"output" => nil}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal: Notification handling
  # ---------------------------------------------------------------------------

  defp handle_notification("session.event", params, state) do
    session_id = params["sessionId"]
    event = params["event"]

    case Map.get(state.sessions, session_id) do
      nil -> :ok
      session_pid -> Session.dispatch_event(session_pid, event)
    end
  end

  defp handle_notification("session.lifecycle", params, state) do
    event = Types.SessionLifecycleEvent.from_map(params)

    for {_ref, handler} <- state.lifecycle_handlers do
      try do
        handler.(event)
      rescue
        _ -> :ok
      end
    end
  end

  defp handle_notification(_method, _params, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internal: Helpers
  # ---------------------------------------------------------------------------

  defp find_cli_path do
    case System.find_executable("copilot") do
      nil -> "copilot"
      path -> path
    end
  end

  defp build_create_params(%SessionConfig{} = c) do
    params = %{}
    params = put_if(params, "sessionId", c.session_id)
    params = put_if(params, "model", c.model)
    params = put_if(params, "reasoningEffort", c.reasoning_effort)
    params = put_if(params, "configDir", c.config_dir)
    params = put_if(params, "workingDirectory", c.working_directory)
    params = put_if(params, "streaming", c.streaming)
    params = put_if(params, "availableTools", c.available_tools)
    params = put_if(params, "excludedTools", c.excluded_tools)
    params = put_if(params, "mcpServers", c.mcp_servers)
    params = put_if(params, "skillDirectories", c.skill_directories)
    params = put_if(params, "disabledSkills", c.disabled_skills)

    params =
      if c.tools do
        Map.put(params, "tools", Enum.map(c.tools, &Tool.to_wire/1))
      else
        params
      end

    params =
      if c.system_message do
        Map.put(params, "systemMessage", system_message_to_map(c.system_message))
      else
        params
      end

    params =
      if c.provider do
        Map.put(params, "provider", provider_to_map(c.provider))
      else
        params
      end

    params = Map.put(params, "requestPermission", c.on_permission_request != nil)
    params = Map.put(params, "requestUserInput", c.on_user_input_request != nil)

    params =
      Map.put(
        params,
        "hooks",
        c.hooks != nil and SessionHooks.any_set?(c.hooks)
      )

    params =
      if c.custom_agents do
        Map.put(params, "customAgents", Enum.map(c.custom_agents, &agent_to_map/1))
      else
        params
      end

    params =
      if c.infinite_sessions do
        Map.put(params, "infiniteSessions", infinite_session_to_map(c.infinite_sessions))
      else
        params
      end

    params
  end

  defp build_resume_params(session_id, %ResumeSessionConfig{} = c) do
    params = %{"sessionId" => session_id}
    params = put_if(params, "model", c.model)
    params = put_if(params, "reasoningEffort", c.reasoning_effort)
    params = put_if(params, "configDir", c.config_dir)
    params = put_if(params, "workingDirectory", c.working_directory)
    params = put_if(params, "streaming", c.streaming)
    params = put_if(params, "availableTools", c.available_tools)
    params = put_if(params, "excludedTools", c.excluded_tools)
    params = put_if(params, "mcpServers", c.mcp_servers)
    params = put_if(params, "skillDirectories", c.skill_directories)
    params = put_if(params, "disabledSkills", c.disabled_skills)
    params = put_if(params, "disableResume", c.disable_resume)

    params =
      if c.tools do
        Map.put(params, "tools", Enum.map(c.tools, &Tool.to_wire/1))
      else
        params
      end

    params =
      if c.system_message do
        Map.put(params, "systemMessage", system_message_to_map(c.system_message))
      else
        params
      end

    params =
      if c.provider do
        Map.put(params, "provider", provider_to_map(c.provider))
      else
        params
      end

    params = Map.put(params, "requestPermission", c.on_permission_request != nil)
    params = Map.put(params, "requestUserInput", c.on_user_input_request != nil)

    params =
      Map.put(
        params,
        "hooks",
        c.hooks != nil and SessionHooks.any_set?(c.hooks)
      )

    params =
      if c.custom_agents do
        Map.put(params, "customAgents", Enum.map(c.custom_agents, &agent_to_map/1))
      else
        params
      end

    params =
      if c.infinite_sessions do
        Map.put(params, "infiniteSessions", infinite_session_to_map(c.infinite_sessions))
      else
        params
      end

    params
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp system_message_to_map(%Types.SystemMessageAppendConfig{} = c),
    do: Types.SystemMessageAppendConfig.to_map(c)

  defp system_message_to_map(%Types.SystemMessageReplaceConfig{} = c),
    do: Types.SystemMessageReplaceConfig.to_map(c)

  defp provider_to_map(%Types.ProviderConfig{} = p) do
    m = %{}
    m = put_if(m, "type", p.type)
    m = put_if(m, "wireApi", p.wire_api)
    m = put_if(m, "baseUrl", p.base_url)
    m = put_if(m, "apiKey", p.api_key)
    m = put_if(m, "bearerToken", p.bearer_token)
    m = put_if(m, "azure", p.azure)
    m
  end

  defp agent_to_map(%Types.CustomAgentConfig{} = a) do
    m = %{"name" => a.name, "prompt" => a.prompt}
    m = put_if(m, "displayName", a.display_name)
    m = put_if(m, "description", a.description)
    m = put_if(m, "tools", a.tools)
    m = put_if(m, "mcpServers", a.mcp_servers)
    m = put_if(m, "infer", a.infer)
    m
  end

  defp infinite_session_to_map(%Types.InfiniteSessionConfig{} = c) do
    m = %{}
    m = put_if(m, "enabled", c.enabled)
    m = put_if(m, "backgroundCompactionThreshold", c.background_compaction_threshold)
    m = put_if(m, "bufferExhaustionThreshold", c.buffer_exhaustion_threshold)
    m
  end
end
