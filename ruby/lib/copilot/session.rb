# frozen_string_literal: true

# Copyright (c) Microsoft Corporation. All rights reserved.

require "thread"

module Copilot
  # Represents a single conversation session with the Copilot CLI.
  #
  # A session maintains conversation state, handles events, and manages tool execution.
  # Sessions are created via {CopilotClient#create_session} or resumed via
  # {CopilotClient#resume_session}.
  #
  # @example Basic usage
  #   session = client.create_session(model: "gpt-4")
  #
  #   # Subscribe to all events
  #   unsub = session.on { |event| puts event.type }
  #
  #   # Send a message and wait for completion
  #   response = session.send_and_wait(prompt: "Hello!")
  #   puts response&.data&.dig("content")
  #
  #   session.destroy
  class CopilotSession
    # @return [String] the unique session identifier
    attr_reader :session_id

    # @return [String, nil] workspace path when infinite sessions are enabled
    attr_reader :workspace_path

    # @api private
    # @param session_id     [String]
    # @param rpc_client     [JsonRpcClient]
    # @param workspace_path [String, nil]
    def initialize(session_id, rpc_client, workspace_path = nil)
      @session_id     = session_id
      @rpc_client     = rpc_client
      @workspace_path = workspace_path

      @event_handlers      = []
      @typed_event_handlers = {} # type => [handler]
      @event_handlers_lock = Mutex.new

      @tool_handlers      = {}
      @tool_handlers_lock = Mutex.new

      @permission_handler      = nil
      @permission_handler_lock = Mutex.new

      @user_input_handler      = nil
      @user_input_handler_lock = Mutex.new

      @hooks      = nil
      @hooks_lock = Mutex.new
    end

    # Send a message to this session.
    #
    # @param prompt          [String]            the message text
    # @param attachments     [Array, nil]        optional file/directory/selection attachments
    # @param mode            [String, nil]       "enqueue" (default) or "immediate"
    # @param response_format [String, nil]       desired response format ("text", "image", "json_object")
    # @param image_options   [ImageOptions, nil] options for image generation
    # @return [String] the message ID
    def send(prompt:, attachments: nil, mode: nil, response_format: nil, image_options: nil)
      payload = { sessionId: @session_id, prompt: prompt }
      payload[:attachments] = attachments if attachments
      payload[:mode] = mode if mode
      payload[:responseFormat] = response_format if response_format
      payload[:imageOptions] = image_options.to_h if image_options
      response = @rpc_client.request("session.send", payload)
      response["messageId"]
    end

    # Send a message and wait until the session becomes idle.
    #
    # This is a convenience method that combines {#send} with waiting for
    # the +session.idle+ event.
    #
    # @param prompt          [String]            the message text
    # @param attachments     [Array, nil]        optional attachments
    # @param mode            [String, nil]       delivery mode
    # @param response_format [String, nil]       desired response format ("text", "image", "json_object")
    # @param image_options   [ImageOptions, nil] options for image generation
    # @param timeout         [Numeric]           seconds to wait (default 60)
    # @return [SessionEvent, nil] the final assistant.message event, or nil
    # @raise [Timeout::Error] if the timeout expires before session.idle
    # @raise [RuntimeError] if the session emits a session.error event
    def send_and_wait(prompt:, attachments: nil, mode: nil, response_format: nil, image_options: nil, timeout: 60)
      idle_mutex = Mutex.new
      idle_cv    = ConditionVariable.new
      idle_fired = false

      last_assistant_message = nil
      error_event = nil

      # Register BEFORE send to avoid race condition
      unsub = on do |event|
        case event.type
        when SessionEventType::ASSISTANT_MESSAGE
          last_assistant_message = event
        when SessionEventType::SESSION_IDLE
          idle_mutex.synchronize do
            idle_fired = true
            idle_cv.signal
          end
        when SessionEventType::SESSION_ERROR
          error_event = RuntimeError.new(
            event.data.is_a?(Hash) ? event.data["message"] : event.data.to_s
          )
          idle_mutex.synchronize do
            idle_fired = true
            idle_cv.signal
          end
        end
      end

      begin
        self.send(prompt: prompt, attachments: attachments, mode: mode,
                  response_format: response_format, image_options: image_options)

        idle_mutex.synchronize do
          unless idle_fired
            idle_cv.wait(idle_mutex, timeout)
          end
        end

        raise error_event if error_event

        unless idle_fired
          raise Timeout::Error, "Timeout after #{timeout}s waiting for session.idle"
        end

        last_assistant_message
      ensure
        unsub.call
      end
    end

    # Subscribe to events from this session.
    #
    # When called with a block only, subscribes to all events.
    # When called with an event type and a block, subscribes to that specific type.
    #
    # @overload on(&handler)
    #   @yield [event] called for every session event
    #   @yieldparam event [SessionEvent]
    #   @return [Proc] unsubscribe function
    #
    # @overload on(event_type, &handler)
    #   @param event_type [String] the specific event type to listen for
    #   @yield [event] called only for events matching the type
    #   @yieldparam event [SessionEvent]
    #   @return [Proc] unsubscribe function
    def on(event_type = nil, &handler)
      raise ArgumentError, "Block required" unless handler

      @event_handlers_lock.synchronize do
        if event_type
          (@typed_event_handlers[event_type] ||= []) << handler
        else
          @event_handlers << handler
        end
      end

      -> {
        @event_handlers_lock.synchronize do
          if event_type
            @typed_event_handlers[event_type]&.delete(handler)
          else
            @event_handlers.delete(handler)
          end
        end
      }
    end

    # Retrieve all events/messages from this session's history.
    #
    # @return [Array<SessionEvent>]
    def get_messages
      response = @rpc_client.request("session.getMessages", { sessionId: @session_id })
      events = response["events"] || []
      events.map { |e| SessionEvent.from_hash(e) }
    end

    # Destroy this session and release associated resources.
    def destroy
      @rpc_client.request("session.destroy", { sessionId: @session_id })
      @event_handlers_lock.synchronize do
        @event_handlers.clear
        @typed_event_handlers.clear
      end
      @tool_handlers_lock.synchronize { @tool_handlers.clear }
      @permission_handler_lock.synchronize { @permission_handler = nil }
      @user_input_handler_lock.synchronize { @user_input_handler = nil }
      @hooks_lock.synchronize { @hooks = nil }
    end

    # Abort the currently processing message.
    def abort
      @rpc_client.request("session.abort", { sessionId: @session_id })
    end

    # ---- Internal API (used by CopilotClient) ----

    # @api private
    def _dispatch_event(event)
      handlers = @event_handlers_lock.synchronize do
        typed = @typed_event_handlers[event.type]&.dup || []
        wildcard = @event_handlers.dup
        typed + wildcard
      end

      handlers.each do |handler|
        handler.call(event)
      rescue StandardError => e
        $stderr.puts("[CopilotSDK] Session event handler error: #{e.class}: #{e.message}")
      end
    end

    # @api private
    def _register_tools(tools)
      @tool_handlers_lock.synchronize do
        @tool_handlers.clear
        return unless tools

        tools.each do |tool|
          next unless tool.name && tool.handler

          @tool_handlers[tool.name] = tool.handler
        end
      end
    end

    # @api private
    def _get_tool_handler(name)
      @tool_handlers_lock.synchronize { @tool_handlers[name] }
    end

    # @api private
    def _register_permission_handler(handler)
      @permission_handler_lock.synchronize { @permission_handler = handler }
    end

    # @api private
    def _handle_permission_request(request)
      handler = @permission_handler_lock.synchronize { @permission_handler }
      unless handler
        return { kind: PermissionKind::DENIED_NO_APPROVAL }
      end

      begin
        perm_request = PermissionRequest.from_hash(request)
        result = handler.call(perm_request, { session_id: @session_id })
        result.is_a?(PermissionRequestResult) ? result.to_h : result
      rescue StandardError
        { kind: PermissionKind::DENIED_NO_APPROVAL }
      end
    end

    # @api private
    def _register_user_input_handler(handler)
      @user_input_handler_lock.synchronize { @user_input_handler = handler }
    end

    # @api private
    def _handle_user_input_request(params)
      handler = @user_input_handler_lock.synchronize { @user_input_handler }
      raise "User input requested but no handler registered" unless handler

      request = UserInputRequest.from_hash(params)
      result = handler.call(request, { session_id: @session_id })
      result.is_a?(UserInputResponse) ? result.to_h : result
    end

    # @api private
    def _register_hooks(hooks)
      @hooks_lock.synchronize { @hooks = hooks }
    end

    # @api private
    def _handle_hooks_invoke(hook_type, input_data)
      hooks = @hooks_lock.synchronize { @hooks }
      return nil unless hooks

      handler_map = {
        "preToolUse"          => hooks.on_pre_tool_use,
        "postToolUse"         => hooks.on_post_tool_use,
        "userPromptSubmitted" => hooks.on_user_prompt_submitted,
        "sessionStart"        => hooks.on_session_start,
        "sessionEnd"          => hooks.on_session_end,
        "errorOccurred"       => hooks.on_error_occurred,
      }

      handler = handler_map[hook_type]
      return nil unless handler

      begin
        handler.call(input_data, { session_id: @session_id })
      rescue StandardError
        nil
      end
    end
  end
end
