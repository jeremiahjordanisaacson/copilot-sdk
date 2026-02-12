defmodule Copilot.JsonRpcClient do
  @moduledoc """
  GenServer-based JSON-RPC 2.0 client using Port for stdio communication.

  Messages are framed with `Content-Length` headers following the LSP base protocol:

      Content-Length: <byte-length>\r\n
      \r\n
      <JSON body>

  The client supports:
  - Outgoing requests (with responses matched by id)
  - Outgoing notifications (no response expected)
  - Incoming notifications from the server
  - Incoming requests from the server (tool.call, permission.request, etc.)
  """

  use GenServer
  require Logger

  @type request_id :: String.t()

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            port: port() | nil,
            buffer: binary(),
            next_id: non_neg_integer(),
            pending: %{String.t() => {pid(), reference()}},
            notification_handler: (String.t(), map() -> :ok) | nil,
            request_handlers: %{String.t() => (map() -> map())},
            os_pid: non_neg_integer() | nil
          }
    defstruct port: nil,
              buffer: <<>>,
              next_id: 1,
              pending: %{},
              notification_handler: nil,
              request_handlers: %{},
              os_pid: nil
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the JSON-RPC client linked to the calling process.

  `port` must be an already-opened Erlang port connected to the CLI subprocess
  via stdin/stdout.
  """
  @spec start_link(port(), keyword()) :: GenServer.on_start()
  def start_link(port, opts \\ []) do
    GenServer.start_link(__MODULE__, port, opts)
  end

  @doc """
  Send a JSON-RPC request and wait for the response.

  Returns `{:ok, result}` or `{:error, %{code: integer, message: String.t()}}`.
  """
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, any()} | {:error, map()}
  def request(client, method, params \\ %{}, timeout \\ 30_000) do
    GenServer.call(client, {:request, method, params}, timeout)
  end

  @doc """
  Send a JSON-RPC notification (no response expected).
  """
  @spec notify(GenServer.server(), String.t(), map()) :: :ok
  def notify(client, method, params \\ %{}) do
    GenServer.cast(client, {:notify, method, params})
  end

  @doc """
  Register a handler for incoming notifications from the server.

  The handler receives `(method, params)` and is called in the GenServer process.
  """
  @spec set_notification_handler(GenServer.server(), (String.t(), map() -> :ok) | nil) :: :ok
  def set_notification_handler(client, handler) do
    GenServer.cast(client, {:set_notification_handler, handler})
  end

  @doc """
  Register a handler for an incoming request method (e.g. `"tool.call"`).

  The handler receives `params` and must return a result map.
  """
  @spec set_request_handler(GenServer.server(), String.t(), (map() -> map()) | nil) :: :ok
  def set_request_handler(client, method, handler) do
    GenServer.cast(client, {:set_request_handler, method, handler})
  end

  @doc "Stop the client and close the port."
  @spec stop(GenServer.server()) :: :ok
  def stop(client) do
    GenServer.stop(client, :normal)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {:ok, %State{port: port, os_pid: os_pid}}
  end

  @impl true
  def handle_call({:request, method, params}, from, %State{} = state) do
    id = Integer.to_string(state.next_id)

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    send_message(state.port, message)

    pending = Map.put(state.pending, id, from)
    {:noreply, %{state | next_id: state.next_id + 1, pending: pending}}
  end

  @impl true
  def handle_cast({:notify, method, params}, %State{} = state) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }

    send_message(state.port, message)
    {:noreply, state}
  end

  def handle_cast({:set_notification_handler, handler}, state) do
    {:noreply, %{state | notification_handler: handler}}
  end

  def handle_cast({:set_request_handler, method, handler}, state) do
    handlers =
      if handler do
        Map.put(state.request_handlers, method, handler)
      else
        Map.delete(state.request_handlers, method)
      end

    {:noreply, %{state | request_handlers: handlers}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %State{port: port} = state) do
    buffer = state.buffer <> data
    state = process_buffer(%{state | buffer: buffer})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _code}}, %State{port: port} = state) do
    # CLI process exited -- reject all pending requests
    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, %{code: -1, message: "CLI process exited"}})
    end

    {:stop, :normal, %{state | port: nil, pending: %{}}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{port: port}) when not is_nil(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Internal: Message framing
  # ---------------------------------------------------------------------------

  defp send_message(port, message) do
    json = Jason.encode!(message)
    byte_size = byte_size(json)
    frame = "Content-Length: #{byte_size}\r\n\r\n#{json}"
    Port.command(port, frame)
  end

  # Try to parse one or more complete messages from the buffer.
  defp process_buffer(%State{buffer: buffer} = state) do
    case parse_frame(buffer) do
      {:ok, json_body, rest} ->
        state = handle_incoming_message(json_body, %{state | buffer: rest})
        process_buffer(state)

      :incomplete ->
        state
    end
  end

  # Parse a single Content-Length framed message from the buffer.
  # Returns {:ok, body_binary, remaining_buffer} or :incomplete
  defp parse_frame(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [header_part, rest] ->
        case parse_content_length(header_part) do
          {:ok, content_length} ->
            if byte_size(rest) >= content_length do
              <<body::binary-size(content_length), remaining::binary>> = rest
              {:ok, body, remaining}
            else
              :incomplete
            end

          :error ->
            :incomplete
        end

      _ ->
        :incomplete
    end
  end

  defp parse_content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        ["Content-Length", value] ->
          case Integer.parse(String.trim(value)) do
            {n, _} -> {:ok, n}
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal: Message dispatch
  # ---------------------------------------------------------------------------

  defp handle_incoming_message(json_body, state) do
    case Jason.decode(json_body) do
      {:ok, message} ->
        dispatch_message(message, state)

      {:error, reason} ->
        Logger.warning("JSON-RPC: failed to decode message: #{inspect(reason)}")
        state
    end
  end

  defp dispatch_message(%{"id" => id, "result" => result} = _msg, state)
       when is_map_key(state.pending, id) do
    {from, pending} = Map.pop(state.pending, id)
    GenServer.reply(from, {:ok, result})
    %{state | pending: pending}
  end

  defp dispatch_message(%{"id" => id, "error" => error} = _msg, state)
       when is_map_key(state.pending, id) do
    {from, pending} = Map.pop(state.pending, id)
    GenServer.reply(from, {:error, error})
    %{state | pending: pending}
  end

  # Incoming request from server (has both "id" and "method")
  defp dispatch_message(%{"id" => id, "method" => method, "params" => params} = _msg, state) do
    handle_incoming_request(id, method, params, state)
    state
  end

  defp dispatch_message(%{"id" => id, "method" => method} = _msg, state) do
    handle_incoming_request(id, method, %{}, state)
    state
  end

  # Incoming notification from server (has "method" but no "id")
  defp dispatch_message(%{"method" => method, "params" => params} = _msg, state) do
    if state.notification_handler do
      try do
        state.notification_handler.(method, params)
      rescue
        e -> Logger.warning("Notification handler error: #{inspect(e)}")
      end
    end

    state
  end

  defp dispatch_message(%{"method" => method} = _msg, state) do
    if state.notification_handler do
      try do
        state.notification_handler.(method, %{})
      rescue
        e -> Logger.warning("Notification handler error: #{inspect(e)}")
      end
    end

    state
  end

  defp dispatch_message(_msg, state), do: state

  # Handle an incoming request from the server.
  # Runs the handler and sends back a JSON-RPC response.
  defp handle_incoming_request(id, method, params, state) do
    case Map.get(state.request_handlers, method) do
      nil ->
        send_error_response(state.port, id, -32601, "Method not found: #{method}")

      handler ->
        # Spawn a task so the GenServer is not blocked during tool execution
        port = state.port

        Task.start(fn ->
          try do
            result = handler.(params)
            send_response(port, id, result || %{})
          rescue
            e ->
              send_error_response(port, id, -32603, Exception.message(e))
          end
        end)
    end
  end

  defp send_response(port, id, result) do
    message = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    send_message(port, message)
  end

  defp send_error_response(port, id, code, message) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }

    send_message(port, msg)
  end
end
