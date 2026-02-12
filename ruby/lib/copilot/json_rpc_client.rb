# frozen_string_literal: true

# Copyright (c) Microsoft Corporation. All rights reserved.

require "json"
require "securerandom"
require "thread"

module Copilot
  # JSON-RPC 2.0 error raised when the server returns an error response.
  class JsonRpcError < StandardError
    attr_reader :code, :data

    def initialize(code, message, data = nil)
      @code = code
      @data = data
      super("JSON-RPC Error #{code}: #{message}")
    end
  end

  # Minimal threaded JSON-RPC 2.0 client for stdio / TCP IO transport.
  #
  # Messages use Content-Length header framing (the LSP/JSON-RPC wire format):
  #   Content-Length: <byte-length>\r\n
  #   \r\n
  #   <JSON payload>
  #
  # The client runs a background reader thread that dispatches:
  # - Responses to pending requests (via per-request Queue)
  # - Notifications to the registered notification handler
  # - Incoming requests (server -> client) to registered request handlers
  class JsonRpcClient
    # @param input  [IO] readable IO (e.g. process stdout or TCP socket)
    # @param output [IO] writable IO (e.g. process stdin  or TCP socket)
    def initialize(input, output)
      @input  = input
      @output = output

      @pending_requests  = {}  # id => Queue
      @pending_lock      = Mutex.new

      @write_lock        = Mutex.new

      @notification_handler = nil  # Proc(method, params)
      @request_handlers     = {}   # method => Proc(params) -> Hash

      @running = false
      @reader_thread = nil
    end

    # Start the background reader thread.
    def start
      return if @running

      @running = true
      @reader_thread = Thread.new { read_loop }
      @reader_thread.abort_on_exception = false
    end

    # Stop the background reader thread.
    def stop
      @running = false
      @reader_thread&.join(2.0)

      # Unblock any pending requests so callers don't hang forever.
      @pending_lock.synchronize do
        @pending_requests.each_value do |queue|
          queue << { __error: JsonRpcError.new(-32000, "Client stopped") }
        end
        @pending_requests.clear
      end
    end

    # Send a JSON-RPC request and wait synchronously for the response.
    #
    # @param method  [String]       the RPC method name
    # @param params  [Hash, nil]    optional parameters
    # @param timeout [Numeric, nil] seconds to wait (default 30)
    # @return [Object] the +result+ from the JSON-RPC response
    # @raise [JsonRpcError] if the server returns an error
    # @raise [Timeout::Error] if the request times out
    def request(method, params = nil, timeout: 30)
      request_id = SecureRandom.uuid
      queue = Queue.new

      @pending_lock.synchronize do
        @pending_requests[request_id] = queue
      end

      send_message({
        jsonrpc: "2.0",
        id: request_id,
        method: method,
        params: params || {},
      })

      response = nil
      begin
        # Queue#pop with a timeout: use Timeout or poll.  We use a simple
        # polling approach to avoid Timeout's thread-safety issues.
        deadline = Time.now + (timeout || 30)
        loop do
          begin
            response = queue.pop(true) # non-blocking
            break
          rescue ThreadError
            # queue empty
            if Time.now > deadline
              raise Timeout::Error, "JSON-RPC request '#{method}' timed out after #{timeout}s"
            end
            sleep 0.01
          end
        end
      ensure
        @pending_lock.synchronize { @pending_requests.delete(request_id) }
      end

      if response.is_a?(Hash) && response.key?(:__error)
        raise response[:__error]
      end

      response
    end

    # Send a JSON-RPC notification (fire-and-forget, no response expected).
    #
    # @param method [String]    the RPC method name
    # @param params [Hash, nil] optional parameters
    def notify(method, params = nil)
      send_message({
        jsonrpc: "2.0",
        method: method,
        params: params || {},
      })
    end

    # Register a handler for incoming notifications from the server.
    # The handler receives +(method, params)+.
    #
    # @yield [method, params]
    def on_notification(&handler)
      @notification_handler = handler
    end

    # Register a handler for incoming requests from the server.
    # The handler receives +(params)+ and must return a Hash result.
    #
    # @param method [String] the RPC method to handle
    # @yield [params] the request parameters
    # @yieldreturn [Hash] the result to send back
    def on_request(method, &handler)
      if handler.nil?
        @request_handlers.delete(method)
      else
        @request_handlers[method] = handler
      end
    end

    private

    # Write a JSON-RPC message with Content-Length framing.
    def send_message(message)
      content = JSON.generate(message)
      content_bytes = content.encode("utf-8")
      header = "Content-Length: #{content_bytes.bytesize}\r\n\r\n"

      @write_lock.synchronize do
        @output.write(header)
        @output.write(content_bytes)
        @output.flush
      end
    end

    # Background loop: read messages and dispatch them.
    def read_loop
      while @running
        message = read_message
        break unless message

        handle_message(message)
      end
    rescue IOError, EOFError, Errno::EPIPE, Errno::ECONNRESET => _e
      # Stream closed; stop gracefully.
    rescue StandardError => e
      $stderr.puts("[CopilotSDK] JSON-RPC read loop error: #{e.class}: #{e.message}") if @running
    end

    # Read a single Content-Length framed JSON-RPC message (blocking).
    #
    # @return [Hash, nil] parsed message or nil on EOF
    def read_message
      # Read header line
      header_line = @input.gets
      return nil if header_line.nil?

      header = header_line.strip
      return nil unless header.start_with?("Content-Length:")

      content_length = header.split(":")[1].strip.to_i

      # Read the blank separator line
      @input.gets

      # Read exact content bytes, handling partial reads
      content_bytes = read_exact(content_length)
      return nil if content_bytes.nil?

      JSON.parse(content_bytes)
    end

    # Read exactly +num_bytes+ from the input, handling partial reads.
    #
    # @param num_bytes [Integer]
    # @return [String, nil]
    def read_exact(num_bytes)
      chunks = []
      remaining = num_bytes
      while remaining > 0
        chunk = @input.read(remaining)
        return nil if chunk.nil? || chunk.empty?

        chunks << chunk
        remaining -= chunk.bytesize
      end
      chunks.join
    end

    # Dispatch an incoming message to the appropriate handler.
    def handle_message(message)
      # Response to a pending request
      if message.key?("id") && (message.key?("result") || message.key?("error"))
        handle_response(message)
        return
      end

      # Notification from server (no id)
      if message.key?("method") && !message.key?("id")
        handle_notification(message)
        return
      end

      # Incoming request from server (has both method and id)
      if message.key?("method") && message.key?("id")
        handle_incoming_request(message)
        return
      end
    end

    # Resolve or reject a pending request.
    def handle_response(message)
      request_id = message["id"]
      queue = @pending_lock.synchronize { @pending_requests[request_id] }
      return unless queue

      if message.key?("error")
        err = message["error"]
        queue << {
          __error: JsonRpcError.new(
            err.fetch("code", -1),
            err.fetch("message", "Unknown error"),
            err["data"]
          )
        }
      elsif message.key?("result")
        queue << message["result"]
      else
        queue << { __error: JsonRpcError.new(-32600, "Invalid JSON-RPC response") }
      end
    end

    # Dispatch a notification to the registered handler.
    def handle_notification(message)
      return unless @notification_handler

      method = message["method"]
      params = message.fetch("params", {})
      @notification_handler.call(method, params)
    rescue StandardError => e
      $stderr.puts("[CopilotSDK] Notification handler error: #{e.class}: #{e.message}")
    end

    # Handle an incoming request from the server and send back a response.
    def handle_incoming_request(message)
      method = message["method"]
      request_id = message["id"]
      params = message.fetch("params", {})

      handler = @request_handlers[method]
      unless handler
        send_error_response(request_id, -32601, "Method not found: #{method}")
        return
      end

      # Execute handler (may be synchronous or may raise)
      begin
        result = handler.call(params)
        result = {} if result.nil?
        send_response(request_id, result)
      rescue JsonRpcError => e
        send_error_response(request_id, e.code, e.message, e.data)
      rescue StandardError => e
        send_error_response(request_id, -32603, e.message)
      end
    end

    # Send a successful response.
    def send_response(request_id, result)
      send_message({
        jsonrpc: "2.0",
        id: request_id,
        result: result,
      })
    end

    # Send an error response.
    def send_error_response(request_id, code, message, data = nil)
      error_obj = { code: code, message: message }
      error_obj[:data] = data if data
      send_message({
        jsonrpc: "2.0",
        id: request_id,
        error: error_obj,
      })
    end
  end
end
