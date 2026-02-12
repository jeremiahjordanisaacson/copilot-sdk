# frozen_string_literal: true

# Copyright (c) Microsoft Corporation. All rights reserved.

require "open3"
require "socket"
require "thread"

module Copilot
  # Main client for interacting with the Copilot CLI.
  #
  # The CopilotClient manages the connection to the Copilot CLI server and provides
  # methods to create and manage conversation sessions. It can either spawn a CLI
  # server process or connect to an existing server.
  #
  # @example
  #   client = Copilot::CopilotClient.new(cli_path: "/usr/local/bin/copilot")
  #   client.start
  #
  #   session = client.create_session(model: "gpt-4")
  #   response = session.send_and_wait(prompt: "Hello!")
  #   puts response&.data&.dig("content")
  #
  #   session.destroy
  #   client.stop
  class CopilotClient
    # @return [String] the current connection state
    attr_reader :state

    # Create a new CopilotClient.
    #
    # @param cli_path         [String, nil]  path to the Copilot CLI executable
    # @param cli_args         [Array<String>] extra arguments for the CLI
    # @param cwd              [String, nil]  working directory for the CLI process
    # @param port             [Integer]      TCP port (0 = random); ignored in stdio mode
    # @param use_stdio        [Boolean]      use stdio transport (default: true)
    # @param cli_url          [String, nil]  URL of an existing server ("host:port")
    # @param log_level        [String]       log level for the CLI ("info", "debug", etc.)
    # @param auto_start       [Boolean]      auto-start on first use (default: true)
    # @param auto_restart     [Boolean]      auto-restart if the server crashes (default: true)
    # @param env              [Hash, nil]    environment variables for the CLI process
    # @param github_token     [String, nil]  GitHub token for authentication
    # @param use_logged_in_user [Boolean, nil] use logged-in user auth (default: true unless github_token)
    #
    # @raise [ArgumentError] if mutually exclusive options are provided
    def initialize(
      cli_path: nil,
      cli_args: [],
      cwd: nil,
      port: 0,
      use_stdio: true,
      cli_url: nil,
      log_level: "info",
      auto_start: true,
      auto_restart: true,
      env: nil,
      github_token: nil,
      use_logged_in_user: nil
    )
      # Validate mutually exclusive options
      if cli_url && (use_stdio == false || cli_path)
        # cli_url with explicit use_stdio=false is fine; but cli_url with cli_path is not
      end
      if cli_url && cli_path
        raise ArgumentError, "cli_url is mutually exclusive with cli_path"
      end
      if cli_url && (github_token || !use_logged_in_user.nil?)
        raise ArgumentError,
              "github_token and use_logged_in_user cannot be used with cli_url " \
              "(external server manages its own auth)"
      end

      @is_external_server = false
      @actual_host = "localhost"
      @actual_port = nil

      if cli_url
        @actual_host, @actual_port = parse_cli_url(cli_url)
        @is_external_server = true
      end

      # Default use_logged_in_user based on github_token
      use_logged_in_user = github_token ? false : true if use_logged_in_user.nil?

      @options = ClientOptions.new(
        cli_path: cli_path || "copilot",
        cli_args: cli_args,
        cwd: cwd || Dir.pwd,
        port: port,
        use_stdio: cli_url ? false : use_stdio,
        cli_url: cli_url,
        log_level: log_level,
        auto_start: auto_start,
        auto_restart: auto_restart,
        env: env,
        github_token: github_token,
        use_logged_in_user: use_logged_in_user,
      )

      @process    = nil
      @stdin      = nil
      @stdout     = nil
      @stderr     = nil
      @rpc_client = nil
      @socket     = nil
      @state      = ConnectionState::DISCONNECTED

      @sessions      = {}
      @sessions_lock = Mutex.new

      @models_cache      = nil
      @models_cache_lock = Mutex.new

      @lifecycle_handlers       = []
      @typed_lifecycle_handlers = {} # type => [handler]
      @lifecycle_handlers_lock  = Mutex.new

      @stderr_thread = nil
    end

    # Start the CLI server and establish a connection.
    #
    # If connecting to an external server (via +cli_url+), only establishes the connection.
    # Otherwise, spawns the CLI server process and then connects.
    #
    # @return [void]
    # @raise [RuntimeError] if the server fails to start or the connection fails
    def start
      return if @state == ConnectionState::CONNECTED

      @state = ConnectionState::CONNECTING
      begin
        start_cli_server unless @is_external_server
        connect_to_server
        verify_protocol_version
        @state = ConnectionState::CONNECTED
      rescue StandardError
        @state = ConnectionState::ERROR
        raise
      end
    end

    # Stop the CLI server and close all active sessions.
    #
    # @return [Array<StopError>] errors encountered during cleanup (empty = success)
    def stop
      errors = []

      # Destroy all active sessions
      sessions_to_destroy = @sessions_lock.synchronize do
        s = @sessions.values.dup
        @sessions.clear
        s
      end

      sessions_to_destroy.each do |session|
        begin
          session.destroy
        rescue StandardError => e
          errors << StopError.new(message: "Failed to destroy session #{session.session_id}: #{e.message}")
        end
      end

      # Stop RPC client
      if @rpc_client
        @rpc_client.stop
        @rpc_client = nil
      end

      # Clear models cache
      @models_cache_lock.synchronize { @models_cache = nil }

      # Close socket if TCP
      if @socket
        begin
          @socket.close
        rescue StandardError => e
          errors << StopError.new(message: "Failed to close socket: #{e.message}")
        end
        @socket = nil
      end

      # Close stdio streams
      [@stdin, @stdout].each do |io|
        begin
          io&.close
        rescue StandardError
          # ignore
        end
      end
      @stdin = @stdout = nil

      # Kill CLI process (only if we spawned it)
      if @process && !@is_external_server
        begin
          Process.kill("TERM", @process)
          Process.wait(@process)
        rescue Errno::ESRCH, Errno::ECHILD
          # Process already gone
        rescue StandardError => e
          errors << StopError.new(message: "Failed to kill CLI process: #{e.message}")
        end
        @process = nil
      end

      @stderr_thread&.join(2.0)
      @stderr_thread = nil

      @state = ConnectionState::DISCONNECTED
      @actual_port = nil unless @is_external_server

      errors
    end

    # Forcefully stop the CLI server without graceful cleanup.
    #
    # @return [void]
    def force_stop
      @sessions_lock.synchronize { @sessions.clear }

      if @rpc_client
        begin
          @rpc_client.stop
        rescue StandardError
          # ignore
        end
        @rpc_client = nil
      end

      @models_cache_lock.synchronize { @models_cache = nil }

      if @socket
        begin
          @socket.close
        rescue StandardError
          # ignore
        end
        @socket = nil
      end

      [@stdin, @stdout].each do |io|
        begin
          io&.close
        rescue StandardError
          # ignore
        end
      end
      @stdin = @stdout = nil

      if @process && !@is_external_server
        begin
          Process.kill("KILL", @process)
          Process.wait(@process)
        rescue StandardError
          # ignore
        end
        @process = nil
      end

      @stderr_thread = nil
      @state = ConnectionState::DISCONNECTED
      @actual_port = nil unless @is_external_server
    end

    # Create a new conversation session.
    #
    # @param config [SessionConfig, Hash] session configuration
    # @return [CopilotSession]
    # @raise [RuntimeError] if not connected and auto_start is disabled
    def create_session(**config)
      ensure_connected!

      payload = build_create_session_payload(config)
      response = @rpc_client.request("session.create", payload)

      session_id = response["sessionId"]
      workspace_path = response["workspacePath"]

      session = CopilotSession.new(session_id, @rpc_client, workspace_path)
      session._register_tools(config[:tools])
      session._register_permission_handler(config[:on_permission_request]) if config[:on_permission_request]
      session._register_user_input_handler(config[:on_user_input_request]) if config[:on_user_input_request]
      session._register_hooks(config[:hooks]) if config[:hooks]

      @sessions_lock.synchronize { @sessions[session_id] = session }
      session
    end

    # Resume an existing session.
    #
    # @param session_id [String] the session ID to resume
    # @param config     [ResumeSessionConfig, Hash] resume configuration
    # @return [CopilotSession]
    def resume_session(session_id, **config)
      ensure_connected!

      payload = build_resume_session_payload(session_id, config)
      response = @rpc_client.request("session.resume", payload)

      resumed_id = response["sessionId"]
      workspace_path = response["workspacePath"]

      session = CopilotSession.new(resumed_id, @rpc_client, workspace_path)
      session._register_tools(config[:tools])
      session._register_permission_handler(config[:on_permission_request]) if config[:on_permission_request]
      session._register_user_input_handler(config[:on_user_input_request]) if config[:on_user_input_request]
      session._register_hooks(config[:hooks]) if config[:hooks]

      @sessions_lock.synchronize { @sessions[resumed_id] = session }
      session
    end

    # Send a ping to verify connectivity.
    #
    # @param message [String, nil] optional message
    # @return [PingResponse]
    def ping(message = nil)
      raise_not_connected! unless @rpc_client

      result = @rpc_client.request("ping", { message: message })
      PingResponse.from_hash(result)
    end

    # Get CLI status including version and protocol information.
    #
    # @return [GetStatusResponse]
    def get_status
      raise_not_connected! unless @rpc_client

      result = @rpc_client.request("status.get", {})
      GetStatusResponse.from_hash(result)
    end

    # Get current authentication status.
    #
    # @return [GetAuthStatusResponse]
    def get_auth_status
      raise_not_connected! unless @rpc_client

      result = @rpc_client.request("auth.getStatus", {})
      GetAuthStatusResponse.from_hash(result)
    end

    # List available models. Results are cached after the first call.
    #
    # @return [Array<ModelInfo>]
    def list_models
      raise_not_connected! unless @rpc_client

      @models_cache_lock.synchronize do
        return @models_cache.dup if @models_cache

        response = @rpc_client.request("models.list", {})
        models_data = response["models"] || []
        @models_cache = models_data.map { |m| ModelInfo.from_hash(m) }
        @models_cache.dup
      end
    end

    # List all sessions known to the server.
    #
    # @return [Array<SessionMetadata>]
    def list_sessions
      raise_not_connected! unless @rpc_client

      response = @rpc_client.request("session.list", {})
      sessions_data = response["sessions"] || []
      sessions_data.map { |s| SessionMetadata.from_hash(s) }
    end

    # Get the last (most recently updated) session ID.
    #
    # @return [String, nil]
    def get_last_session_id
      raise_not_connected! unless @rpc_client

      response = @rpc_client.request("session.getLastId", {})
      response["sessionId"]
    end

    # Delete a session permanently.
    #
    # @param session_id [String]
    # @return [void]
    # @raise [RuntimeError] if deletion fails
    def delete_session(session_id)
      raise_not_connected! unless @rpc_client

      response = @rpc_client.request("session.delete", { sessionId: session_id })
      unless response["success"]
        error = response["error"] || "Unknown error"
        raise "Failed to delete session #{session_id}: #{error}"
      end

      @sessions_lock.synchronize { @sessions.delete(session_id) }
    end

    # Get the foreground session ID (TUI+server mode).
    #
    # @return [String, nil]
    def get_foreground_session_id
      raise_not_connected! unless @rpc_client

      response = @rpc_client.request("session.getForeground", {})
      response["sessionId"]
    end

    # Set the foreground session (TUI+server mode).
    #
    # @param session_id [String]
    # @return [void]
    def set_foreground_session_id(session_id)
      raise_not_connected! unless @rpc_client

      response = @rpc_client.request("session.setForeground", { sessionId: session_id })
      unless response["success"]
        raise response["error"] || "Failed to set foreground session"
      end
    end

    # Subscribe to session lifecycle events.
    #
    # @overload on(&handler)
    #   Subscribe to all lifecycle events.
    #   @yield [event] called for every lifecycle event
    #   @yieldparam event [SessionLifecycleEvent]
    #   @return [Proc] unsubscribe function
    #
    # @overload on(event_type, &handler)
    #   Subscribe to a specific lifecycle event type.
    #   @param event_type [String]
    #   @yield [event]
    #   @yieldparam event [SessionLifecycleEvent]
    #   @return [Proc] unsubscribe function
    def on(event_type = nil, &handler)
      raise ArgumentError, "Block required" unless handler

      @lifecycle_handlers_lock.synchronize do
        if event_type
          (@typed_lifecycle_handlers[event_type] ||= []) << handler
        else
          @lifecycle_handlers << handler
        end
      end

      -> {
        @lifecycle_handlers_lock.synchronize do
          if event_type
            @typed_lifecycle_handlers[event_type]&.delete(handler)
          else
            @lifecycle_handlers.delete(handler)
          end
        end
      }
    end

    private

    def ensure_connected!
      return if @rpc_client

      if @options.auto_start
        start
      else
        raise_not_connected!
      end
    end

    def raise_not_connected!
      raise "Client not connected. Call start() first."
    end

    def parse_cli_url(url)
      clean = url.sub(%r{^https?://}, "")

      if clean.match?(/\A\d+\z/)
        port = clean.to_i
        raise ArgumentError, "Invalid port in cli_url: #{url}" if port <= 0 || port > 65535

        return ["localhost", port]
      end

      parts = clean.split(":")
      raise ArgumentError, "Invalid cli_url format: #{url}" unless parts.length == 2

      host = parts[0].empty? ? "localhost" : parts[0]
      port = parts[1].to_i
      raise ArgumentError, "Invalid port in cli_url: #{url}" if port <= 0 || port > 65535

      [host, port]
    end

    def start_cli_server
      cli_path = @options.cli_path

      unless File.exist?(cli_path) || which(cli_path)
        raise "Copilot CLI not found at #{cli_path}"
      end

      args = []
      args.concat(@options.cli_args) if @options.cli_args
      args.push("--headless", "--no-auto-update", "--log-level", @options.log_level)

      # Auth flags
      if @options.github_token
        args.push("--auth-token-env", "COPILOT_SDK_AUTH_TOKEN")
      end
      unless @options.use_logged_in_user
        args.push("--no-auto-login")
      end

      # Transport mode
      if @options.use_stdio
        args.push("--stdio")
      elsif @options.port > 0
        args.push("--port", @options.port.to_s)
      end

      # Build environment
      spawn_env = @options.env ? @options.env.dup : ENV.to_h
      spawn_env["COPILOT_SDK_AUTH_TOKEN"] = @options.github_token if @options.github_token

      cmd = [cli_path] + args

      if @options.use_stdio
        @stdin, @stdout, @stderr, wait_thr = Open3.popen3(spawn_env, *cmd, chdir: @options.cwd)
        @process = wait_thr.pid

        # Forward stderr in background
        @stderr_thread = Thread.new do
          @stderr.each_line do |line|
            $stderr.puts("[CLI subprocess] #{line.rstrip}") unless line.strip.empty?
          end
        rescue IOError
          # stream closed
        end
      else
        @stdin, @stdout, @stderr, wait_thr = Open3.popen3(spawn_env, *cmd, chdir: @options.cwd)
        @process = wait_thr.pid

        # Wait for port announcement
        deadline = Time.now + 10
        found = false
        @stdout.each_line do |line|
          if (match = line.match(/listening on port (\d+)/i))
            @actual_port = match[1].to_i
            found = true
            break
          end
          break if Time.now > deadline
        end

        raise "Timeout waiting for CLI server to start" unless found
      end
    end

    def connect_to_server
      if @options.use_stdio
        connect_via_stdio
      else
        connect_via_tcp
      end
    end

    def connect_via_stdio
      raise "CLI process not started" unless @stdout && @stdin

      @rpc_client = JsonRpcClient.new(@stdout, @stdin)
      attach_connection_handlers
      @rpc_client.start
    end

    def connect_via_tcp
      raise "Server port not available" unless @actual_port

      @socket = TCPSocket.new(@actual_host, @actual_port)
      @rpc_client = JsonRpcClient.new(@socket, @socket)
      attach_connection_handlers
      @rpc_client.start
    end

    def attach_connection_handlers
      # Notifications
      @rpc_client.on_notification do |method, params|
        case method
        when "session.event"
          handle_session_event_notification(params)
        when "session.lifecycle"
          handle_session_lifecycle_notification(params)
        end
      end

      # Server -> Client requests
      @rpc_client.on_request("tool.call") do |params|
        handle_tool_call_request(params)
      end

      @rpc_client.on_request("permission.request") do |params|
        handle_permission_request(params)
      end

      @rpc_client.on_request("userInput.request") do |params|
        handle_user_input_request(params)
      end

      @rpc_client.on_request("hooks.invoke") do |params|
        handle_hooks_invoke(params)
      end
    end

    def verify_protocol_version
      expected = Copilot.sdk_protocol_version
      result = ping
      server_version = result.protocol_version

      if server_version.nil?
        raise "SDK protocol version mismatch: SDK expects version #{expected}, " \
              "but server does not report a protocol version. " \
              "Please update your server to ensure compatibility."
      end

      if server_version != expected
        raise "SDK protocol version mismatch: SDK expects version #{expected}, " \
              "but server reports version #{server_version}. " \
              "Please update your SDK or server to ensure compatibility."
      end
    end

    # ---- Notification handlers ----

    def handle_session_event_notification(params)
      session_id = params["sessionId"]
      event_hash = params["event"]
      return unless session_id && event_hash

      event = SessionEvent.from_hash(event_hash)
      session = @sessions_lock.synchronize { @sessions[session_id] }
      session&._dispatch_event(event)
    end

    def handle_session_lifecycle_notification(params)
      event = SessionLifecycleEvent.from_hash(params)

      handlers = @lifecycle_handlers_lock.synchronize do
        typed = @typed_lifecycle_handlers[event.type]&.dup || []
        wildcard = @lifecycle_handlers.dup
        typed + wildcard
      end

      handlers.each do |handler|
        handler.call(event)
      rescue StandardError
        # ignore handler errors
      end
    end

    # ---- Server request handlers ----

    def handle_tool_call_request(params)
      session_id = params["sessionId"]
      tool_call_id = params["toolCallId"]
      tool_name = params["toolName"]
      arguments = params["arguments"]

      raise "Invalid tool call payload" unless session_id && tool_call_id && tool_name

      session = @sessions_lock.synchronize { @sessions[session_id] }
      raise "Unknown session #{session_id}" unless session

      handler = session._get_tool_handler(tool_name)
      unless handler
        return { result: build_unsupported_tool_result(tool_name) }
      end

      execute_tool_call(session_id, tool_call_id, tool_name, arguments, handler)
    end

    def execute_tool_call(session_id, tool_call_id, tool_name, arguments, handler)
      invocation = ToolInvocation.new(
        session_id: session_id,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        arguments: arguments
      )

      begin
        result = handler.call(arguments, invocation)
        { result: Copilot.normalize_tool_result(result) }
      rescue StandardError => e
        {
          result: {
            textResultForLlm: "Invoking this tool produced an error. Detailed information is not available.",
            resultType: ToolResultType::FAILURE,
            error: e.message,
            toolTelemetry: {},
          }
        }
      end
    end

    def handle_permission_request(params)
      session_id = params["sessionId"]
      permission_request = params["permissionRequest"]

      raise "Invalid permission request payload" unless session_id && permission_request

      session = @sessions_lock.synchronize { @sessions[session_id] }
      raise "Session not found: #{session_id}" unless session

      begin
        result = session._handle_permission_request(permission_request)
        { result: result }
      rescue StandardError
        { result: { kind: PermissionKind::DENIED_NO_APPROVAL } }
      end
    end

    def handle_user_input_request(params)
      session_id = params["sessionId"]
      question = params["question"]

      raise "Invalid user input request payload" unless session_id && question

      session = @sessions_lock.synchronize { @sessions[session_id] }
      raise "Session not found: #{session_id}" unless session

      result = session._handle_user_input_request(params)
      { answer: result[:answer], wasFreeform: result[:wasFreeform] }
    end

    def handle_hooks_invoke(params)
      session_id = params["sessionId"]
      hook_type = params["hookType"]
      input_data = params["input"]

      raise "Invalid hooks invoke payload" unless session_id && hook_type

      session = @sessions_lock.synchronize { @sessions[session_id] }
      raise "Session not found: #{session_id}" unless session

      output = session._handle_hooks_invoke(hook_type, input_data)
      { output: output }
    end

    # ---- Payload builders ----

    def build_create_session_payload(config)
      payload = {}

      payload[:model] = config[:model] if config[:model]
      payload[:sessionId] = config[:session_id] if config[:session_id]
      payload[:reasoningEffort] = config[:reasoning_effort] if config[:reasoning_effort]
      payload[:configDir] = config[:config_dir] if config[:config_dir]

      if config[:tools]
        payload[:tools] = config[:tools].map(&:to_wire)
      end

      payload[:systemMessage] = convert_system_message(config[:system_message]) if config[:system_message]
      payload[:availableTools] = config[:available_tools] if config[:available_tools]
      payload[:excludedTools] = config[:excluded_tools] if config[:excluded_tools]
      payload[:requestPermission] = true if config[:on_permission_request]
      payload[:requestUserInput] = true if config[:on_user_input_request]
      payload[:hooks] = true if config[:hooks]&.respond_to?(:any_handler?) && config[:hooks].any_handler?
      payload[:workingDirectory] = config[:working_directory] if config[:working_directory]
      payload[:streaming] = config[:streaming] unless config[:streaming].nil?

      if config[:provider]
        payload[:provider] = config[:provider].respond_to?(:to_wire) ? config[:provider].to_wire : config[:provider]
      end

      payload[:mcpServers] = config[:mcp_servers] if config[:mcp_servers]

      if config[:custom_agents]
        payload[:customAgents] = config[:custom_agents].map { |a|
          a.respond_to?(:to_wire) ? a.to_wire : a
        }
      end

      payload[:skillDirectories] = config[:skill_directories] if config[:skill_directories]
      payload[:disabledSkills] = config[:disabled_skills] if config[:disabled_skills]

      if config[:infinite_sessions]
        is_cfg = config[:infinite_sessions]
        payload[:infiniteSessions] = is_cfg.respond_to?(:to_wire) ? is_cfg.to_wire : is_cfg
      end

      payload
    end

    def build_resume_session_payload(session_id, config)
      payload = build_create_session_payload(config)
      payload[:sessionId] = session_id
      payload[:disableResume] = config[:disable_resume] if config[:disable_resume]
      payload
    end

    def convert_system_message(msg)
      return msg if msg.is_a?(Hash)

      msg.respond_to?(:to_h) ? msg.to_h : msg
    end

    def build_unsupported_tool_result(tool_name)
      {
        textResultForLlm: "Tool '#{tool_name}' is not supported by this client instance.",
        resultType: ToolResultType::FAILURE,
        error: "tool '#{tool_name}' not supported",
        toolTelemetry: {},
      }
    end

    # Check if a command exists on PATH.
    def which(cmd)
      exts = ENV["PATHEXT"] ? ENV["PATHEXT"].split(";") : [""]
      ENV["PATH"].split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable?(exe) && !File.directory?(exe)
        end
      end
      nil
    end
  end
end
