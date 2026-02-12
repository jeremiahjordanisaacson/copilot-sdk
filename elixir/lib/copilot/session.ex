defmodule Copilot.Session do
  @moduledoc """
  Represents a single conversation session with the Copilot CLI.

  A session maintains conversation state, handles events, and manages tool
  execution. Sessions are created via `Copilot.Client.create_session/2` or
  resumed via `Copilot.Client.resume_session/3`.

  ## Event subscriptions

  Use `on/2` (all events) or `on/3` (typed events) to subscribe. The returned
  reference can be passed to `off/2` to unsubscribe.

  ## Example

      {:ok, session} = Copilot.Client.create_session(client)
      ref = Copilot.Session.on(session, fn event -> IO.inspect(event) end)
      {:ok, response} = Copilot.Session.send_and_wait(session, %MessageOptions{prompt: "Hi"})
      Copilot.Session.off(session, ref)
      Copilot.Session.destroy(session)
  """

  use GenServer
  require Logger

  alias Copilot.JsonRpcClient
  alias Copilot.Types
  alias Copilot.Types.{
    MessageOptions,
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
            session_id: String.t(),
            rpc: pid(),
            workspace_path: String.t() | nil,
            tool_handlers: %{String.t() => fun()},
            permission_handler: fun() | nil,
            user_input_handler: fun() | nil,
            hooks: SessionHooks.t() | nil,
            event_handlers: [{reference(), fun()}],
            typed_event_handlers: %{String.t() => [{reference(), fun()}]},
            waiters: [{reference(), pid(), any()}]
          }
    defstruct session_id: "",
              rpc: nil,
              workspace_path: nil,
              tool_handlers: %{},
              permission_handler: nil,
              user_input_handler: nil,
              hooks: nil,
              event_handlers: [],
              typed_event_handlers: %{},
              waiters: []
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a message to the session (fire-and-forget).

  Returns `{:ok, message_id}` on success.
  """
  @spec send(GenServer.server(), MessageOptions.t()) :: {:ok, String.t()} | {:error, any()}
  def send(session, %MessageOptions{} = options) do
    GenServer.call(session, {:send, options}, 30_000)
  end

  @doc """
  Send a message and wait for the session to become idle.

  Returns `{:ok, assistant_message_event | nil}` when done,
  or `{:error, reason}` on timeout/error.
  """
  @spec send_and_wait(GenServer.server(), MessageOptions.t(), timeout()) ::
          {:ok, map() | nil} | {:error, any()}
  def send_and_wait(session, %MessageOptions{} = options, timeout \\ 60_000) do
    GenServer.call(session, {:send_and_wait, options, timeout}, timeout + 5_000)
  end

  @doc """
  Subscribe to all session events.

  Returns a reference for unsubscribing with `off/2`.
  """
  @spec on(GenServer.server(), (map() -> any())) :: reference()
  def on(session, handler) when is_function(handler, 1) do
    GenServer.call(session, {:subscribe, handler})
  end

  @doc """
  Subscribe to a specific event type (e.g. `"assistant.message"`).

  Returns a reference for unsubscribing with `off/2`.
  """
  @spec on(GenServer.server(), String.t(), (map() -> any())) :: reference()
  def on(session, event_type, handler) when is_binary(event_type) and is_function(handler, 1) do
    GenServer.call(session, {:subscribe_typed, event_type, handler})
  end

  @doc "Unsubscribe an event handler by reference."
  @spec off(GenServer.server(), reference()) :: :ok
  def off(session, ref) do
    GenServer.cast(session, {:unsubscribe, ref})
  end

  @doc "Get all session messages/events from history."
  @spec get_messages(GenServer.server()) :: {:ok, [map()]} | {:error, any()}
  def get_messages(session) do
    GenServer.call(session, :get_messages, 30_000)
  end

  @doc "Get the session ID."
  @spec session_id(GenServer.server()) :: String.t()
  def session_id(session) do
    GenServer.call(session, :session_id)
  end

  @doc "Get the workspace path (when infinite sessions are enabled)."
  @spec workspace_path(GenServer.server()) :: String.t() | nil
  def workspace_path(session) do
    GenServer.call(session, :workspace_path)
  end

  @doc "Abort the currently processing message."
  @spec abort(GenServer.server()) :: :ok | {:error, any()}
  def abort(session) do
    GenServer.call(session, :abort, 10_000)
  end

  @doc "Destroy this session and release all resources."
  @spec destroy(GenServer.server()) :: :ok
  def destroy(session) do
    GenServer.call(session, :destroy, 10_000)
  catch
    :exit, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Internal API (called by Client)
  # ---------------------------------------------------------------------------

  @doc false
  @spec dispatch_event(GenServer.server(), map()) :: :ok
  def dispatch_event(session, event) do
    GenServer.cast(session, {:dispatch_event, event})
  end

  @doc false
  @spec handle_tool_call(GenServer.server(), String.t(), any(), ToolInvocation.t()) ::
          {:ok, map()} | {:error, String.t()}
  def handle_tool_call(session, tool_name, arguments, invocation) do
    GenServer.call(session, {:handle_tool_call, tool_name, arguments, invocation}, 120_000)
  end

  @doc false
  @spec handle_permission_request(GenServer.server(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def handle_permission_request(session, request) do
    GenServer.call(session, {:handle_permission_request, request}, 60_000)
  end

  @doc false
  @spec handle_user_input_request(GenServer.server(), UserInputRequest.t()) ::
          {:ok, map()} | {:error, String.t()}
  def handle_user_input_request(session, request) do
    GenServer.call(session, {:handle_user_input_request, request}, 120_000)
  end

  @doc false
  @spec handle_hooks_invoke(GenServer.server(), String.t(), any()) ::
          {:ok, any()} | {:error, String.t()}
  def handle_hooks_invoke(session, hook_type, input) do
    GenServer.call(session, {:handle_hooks_invoke, hook_type, input}, 30_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    rpc = Keyword.fetch!(opts, :rpc)
    workspace_path = Keyword.get(opts, :workspace_path)
    tools = Keyword.get(opts, :tools)
    on_permission_request = Keyword.get(opts, :on_permission_request)
    on_user_input_request = Keyword.get(opts, :on_user_input_request)
    hooks = Keyword.get(opts, :hooks)

    tool_handlers =
      if tools do
        tools
        |> Enum.map(fn %Tool{name: name, handler: handler} -> {name, handler} end)
        |> Map.new()
      else
        %{}
      end

    {:ok,
     %State{
       session_id: session_id,
       rpc: rpc,
       workspace_path: workspace_path,
       tool_handlers: tool_handlers,
       permission_handler: on_permission_request,
       user_input_handler: on_user_input_request,
       hooks: hooks
     }}
  end

  @impl true
  def handle_call({:send, options}, _from, state) do
    params = %{
      "sessionId" => state.session_id,
      "prompt" => options.prompt
    }

    params = if options.attachments, do: Map.put(params, "attachments", options.attachments), else: params
    params = if options.mode, do: Map.put(params, "mode", options.mode), else: params
    params = if options.response_format, do: Map.put(params, "responseFormat", Types.response_format_to_string(options.response_format)), else: params
    params = if options.image_options, do: Map.put(params, "imageOptions", options.image_options), else: params

    case JsonRpcClient.request(state.rpc, "session.send", params, 30_000) do
      {:ok, %{"messageId" => mid}} -> {:reply, {:ok, mid}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:send_and_wait, options, timeout}, from, state) do
    # Register a waiter that tracks the idle event
    waiter_ref = make_ref()

    waiter = %{
      ref: waiter_ref,
      from: from,
      last_assistant_message: nil,
      timer_ref: nil
    }

    # Set up a timeout timer
    timer_ref = Process.send_after(self(), {:waiter_timeout, waiter_ref}, timeout)
    waiter = %{waiter | timer_ref: timer_ref}

    state = %{state | waiters: [waiter | state.waiters]}

    # Now send the message
    params = %{
      "sessionId" => state.session_id,
      "prompt" => options.prompt
    }

    params = if options.attachments, do: Map.put(params, "attachments", options.attachments), else: params
    params = if options.mode, do: Map.put(params, "mode", options.mode), else: params
    params = if options.response_format, do: Map.put(params, "responseFormat", Types.response_format_to_string(options.response_format)), else: params
    params = if options.image_options, do: Map.put(params, "imageOptions", options.image_options), else: params

    case JsonRpcClient.request(state.rpc, "session.send", params, 30_000) do
      {:ok, _} ->
        # Don't reply yet -- we wait for session.idle
        {:noreply, state}

      {:error, reason} ->
        # Clean up waiter and reply with error
        Process.cancel_timer(timer_ref)
        state = remove_waiter(state, waiter_ref)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, handler}, _from, state) do
    ref = make_ref()
    handlers = [{ref, handler} | state.event_handlers]
    {:reply, ref, %{state | event_handlers: handlers}}
  end

  def handle_call({:subscribe_typed, event_type, handler}, _from, state) do
    ref = make_ref()
    typed = state.typed_event_handlers
    existing = Map.get(typed, event_type, [])
    typed = Map.put(typed, event_type, [{ref, handler} | existing])
    {:reply, ref, %{state | typed_event_handlers: typed}}
  end

  def handle_call(:get_messages, _from, state) do
    case JsonRpcClient.request(state.rpc, "session.getMessages", %{"sessionId" => state.session_id}, 30_000) do
      {:ok, %{"events" => events}} -> {:reply, {:ok, events}, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call(:workspace_path, _from, state) do
    {:reply, state.workspace_path, state}
  end

  def handle_call(:abort, _from, state) do
    case JsonRpcClient.request(state.rpc, "session.abort", %{"sessionId" => state.session_id}) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:destroy, _from, state) do
    JsonRpcClient.request(state.rpc, "session.destroy", %{"sessionId" => state.session_id})

    # Cancel all waiter timers
    for waiter <- state.waiters do
      if waiter.timer_ref, do: Process.cancel_timer(waiter.timer_ref)
    end

    {:stop, :normal, :ok, %{state | event_handlers: [], typed_event_handlers: %{}, tool_handlers: %{}, waiters: []}}
  end

  # ---------------------------------------------------------------------------
  # Tool call handling
  # ---------------------------------------------------------------------------

  def handle_call({:handle_tool_call, tool_name, arguments, invocation}, _from, state) do
    case Map.get(state.tool_handlers, tool_name) do
      nil ->
        result = %{
          "textResultForLlm" => "Tool '#{tool_name}' is not supported by this client instance.",
          "resultType" => "failure",
          "error" => "tool '#{tool_name}' not supported",
          "toolTelemetry" => %{}
        }

        {:reply, {:ok, result}, state}

      handler ->
        try do
          raw_result = handler.(arguments, invocation)
          result = normalize_tool_result(raw_result)
          {:reply, {:ok, result}, state}
        rescue
          e ->
            {:reply, {:error, Exception.message(e)}, state}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Permission request handling
  # ---------------------------------------------------------------------------

  def handle_call({:handle_permission_request, request_map}, _from, state) do
    case state.permission_handler do
      nil ->
        {:reply,
         {:ok, %{"kind" => "denied-no-approval-rule-and-could-not-request-from-user"}},
         state}

      handler ->
        try do
          perm_req = PermissionRequest.from_map(request_map)
          result = handler.(perm_req, %{session_id: state.session_id})
          {:reply, {:ok, PermissionRequestResult.to_map(result)}, state}
        rescue
          e ->
            Logger.warning("Permission handler error: #{inspect(e)}")

            {:reply,
             {:ok, %{"kind" => "denied-no-approval-rule-and-could-not-request-from-user"}},
             state}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # User input request handling
  # ---------------------------------------------------------------------------

  def handle_call({:handle_user_input_request, request}, _from, state) do
    case state.user_input_handler do
      nil ->
        {:reply, {:error, "User input requested but no handler registered"}, state}

      handler ->
        try do
          result = handler.(request, %{session_id: state.session_id})
          {:reply, {:ok, UserInputResponse.to_map(result)}, state}
        rescue
          e ->
            {:reply, {:error, Exception.message(e)}, state}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Hooks invocation
  # ---------------------------------------------------------------------------

  def handle_call({:handle_hooks_invoke, hook_type, input}, _from, state) do
    case state.hooks do
      nil ->
        {:reply, {:ok, nil}, state}

      hooks ->
        case SessionHooks.handler_for(hooks, hook_type) do
          nil ->
            {:reply, {:ok, nil}, state}

          handler ->
            try do
              result = handler.(input, %{session_id: state.session_id})
              {:reply, {:ok, result}, state}
            rescue
              e ->
                Logger.warning("Hook handler error: #{inspect(e)}")
                {:reply, {:ok, nil}, state}
            end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Event dispatch
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:dispatch_event, event}, state) do
    event_type = event["type"]

    # Dispatch to typed handlers
    typed_handlers = Map.get(state.typed_event_handlers, event_type, [])

    for {_ref, handler} <- typed_handlers do
      try do
        handler.(event)
      rescue
        e -> Logger.warning("Typed event handler error: #{inspect(e)}")
      end
    end

    # Dispatch to wildcard handlers
    for {_ref, handler} <- state.event_handlers do
      try do
        handler.(event)
      rescue
        e -> Logger.warning("Event handler error: #{inspect(e)}")
      end
    end

    # Check waiters
    state = process_waiters(event, state)

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, ref}, state) do
    event_handlers = Enum.reject(state.event_handlers, fn {r, _} -> r == ref end)

    typed_event_handlers =
      Map.new(state.typed_event_handlers, fn {type, handlers} ->
        {type, Enum.reject(handlers, fn {r, _} -> r == ref end)}
      end)

    {:noreply, %{state | event_handlers: event_handlers, typed_event_handlers: typed_event_handlers}}
  end

  # ---------------------------------------------------------------------------
  # Waiter timeout
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:waiter_timeout, waiter_ref}, state) do
    case Enum.find(state.waiters, fn w -> w.ref == waiter_ref end) do
      nil ->
        {:noreply, state}

      waiter ->
        GenServer.reply(waiter.from, {:error, :timeout})
        state = remove_waiter(state, waiter_ref)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp process_waiters(%{"type" => "assistant.message"} = event, state) do
    waiters =
      Enum.map(state.waiters, fn waiter ->
        %{waiter | last_assistant_message: event}
      end)

    %{state | waiters: waiters}
  end

  defp process_waiters(%{"type" => "session.idle"}, state) do
    for waiter <- state.waiters do
      if waiter.timer_ref, do: Process.cancel_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, {:ok, waiter.last_assistant_message})
    end

    %{state | waiters: []}
  end

  defp process_waiters(%{"type" => "session.error", "data" => %{"message" => msg}}, state) do
    for waiter <- state.waiters do
      if waiter.timer_ref, do: Process.cancel_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, {:error, msg})
    end

    %{state | waiters: []}
  end

  defp process_waiters(_event, state), do: state

  defp remove_waiter(state, ref) do
    waiters = Enum.reject(state.waiters, fn w -> w.ref == ref end)
    %{state | waiters: waiters}
  end

  defp normalize_tool_result(%ToolResult{} = r) do
    ToolResult.to_map(r)
  end

  defp normalize_tool_result(result) when is_binary(result) do
    %{
      "textResultForLlm" => result,
      "resultType" => "success",
      "toolTelemetry" => %{}
    }
  end

  defp normalize_tool_result(nil) do
    %{
      "textResultForLlm" => "Tool returned no result",
      "resultType" => "failure",
      "error" => "tool returned no result",
      "toolTelemetry" => %{}
    }
  end

  defp normalize_tool_result(%{"textResultForLlm" => _, "resultType" => _} = result) do
    result
  end

  defp normalize_tool_result(result) when is_map(result) do
    %{
      "textResultForLlm" => Jason.encode!(result),
      "resultType" => "success",
      "toolTelemetry" => %{}
    }
  end

  defp normalize_tool_result(result) do
    %{
      "textResultForLlm" => inspect(result),
      "resultType" => "success",
      "toolTelemetry" => %{}
    }
  end
end
