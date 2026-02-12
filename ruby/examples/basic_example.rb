#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright (c) Microsoft Corporation. All rights reserved.

# Basic example of using the Copilot Ruby SDK.
#
# Prerequisites:
#   1. Install the Copilot CLI (https://github.com/github/copilot)
#   2. Authenticate via `copilot auth login` or set GITHUB_TOKEN
#
# Usage:
#   ruby examples/basic_example.rb

require_relative "../lib/copilot"

# ------------------------------------------------------------------
# 1. Define custom tools
# ------------------------------------------------------------------

weather_tool = Copilot.define_tool(
  name: "get_weather",
  description: "Get the current weather for a city",
  parameters: {
    type: "object",
    properties: {
      city: { type: "string", description: "The city name" },
      unit: { type: "string", enum: %w[celsius fahrenheit], description: "Temperature unit" },
    },
    required: ["city"],
  }
) do |args, _invocation|
  city = args["city"] || args[:city]
  unit = args["unit"] || args[:unit] || "celsius"
  # In a real tool you'd call a weather API here.
  "The weather in #{city} is 22 degrees #{unit} and sunny."
end

calculator_tool = Copilot.define_tool(
  name: "calculator",
  description: "Evaluate a simple mathematical expression",
  parameters: {
    type: "object",
    properties: {
      expression: { type: "string", description: "Math expression to evaluate" },
    },
    required: ["expression"],
  }
) do |args, _invocation|
  expr = args["expression"] || args[:expression]
  # WARNING: eval is used here for demonstration only. Never eval untrusted input in production.
  result = eval(expr) # rubocop:disable Security/Eval
  Copilot::ToolResult.new(
    text_result_for_llm: "Result: #{result}",
    result_type: Copilot::ToolResultType::SUCCESS,
    tool_telemetry: { expression: expr, result: result }
  )
end

# ------------------------------------------------------------------
# 2. Create client and session
# ------------------------------------------------------------------

# Set the path to your Copilot CLI binary. Adjust as needed.
cli_path = ENV["COPILOT_CLI_PATH"] || "copilot"

puts "Creating Copilot client..."
client = Copilot::CopilotClient.new(
  cli_path: cli_path,
  log_level: "info"
)

begin
  client.start
  puts "Connected! State: #{client.state}"

  # Ping the server
  ping_response = client.ping("hello from Ruby SDK")
  puts "Ping response: #{ping_response.message} (protocol v#{ping_response.protocol_version})"

  # List available models
  models = client.list_models
  puts "Available models: #{models.map(&:id).join(', ')}"

  # Create a session with tools
  puts "\nCreating session..."
  session = client.create_session(
    tools: [weather_tool, calculator_tool],
    on_permission_request: ->(request, ctx) {
      puts "Permission requested: #{request.kind}"
      # Auto-approve for this example
      Copilot::PermissionRequestResult.new(kind: Copilot::PermissionKind::APPROVED)
    },
    on_user_input_request: ->(request, ctx) {
      puts "Agent asks: #{request.question}"
      print "> "
      answer = $stdin.gets&.chomp || ""
      Copilot::UserInputResponse.new(answer: answer, was_freeform: true)
    }
  )
  puts "Session created: #{session.session_id}"

  # Subscribe to events
  unsub = session.on do |event|
    case event.type
    when Copilot::SessionEventType::ASSISTANT_MESSAGE
      content = event.data["content"] || event.data[:content]
      puts "\nAssistant: #{content}"
    when Copilot::SessionEventType::TOOL_EXECUTION_START
      tool = event.data["toolName"] || event.data[:toolName]
      puts "  [Tool: #{tool}]"
    when Copilot::SessionEventType::TOOL_EXECUTION_COMPLETE
      success = event.data["success"]
      puts "  [Tool complete: #{success ? 'OK' : 'FAILED'}]"
    when Copilot::SessionEventType::SESSION_ERROR
      msg = event.data["message"] || event.data[:message]
      puts "  [ERROR: #{msg}]"
    end
  end

  # ------------------------------------------------------------------
  # 3. Send messages
  # ------------------------------------------------------------------

  puts "\nSending: What's the weather in Tokyo?"
  response = session.send_and_wait(prompt: "What's the weather in Tokyo?", timeout: 120)
  if response
    puts "Final response received."
  end

  puts "\nSending: What is 42 * 17 + 3?"
  response = session.send_and_wait(prompt: "What is 42 * 17 + 3?", timeout: 120)
  if response
    puts "Final response received."
  end

  # ------------------------------------------------------------------
  # 4. Retrieve history
  # ------------------------------------------------------------------

  puts "\n--- Session History ---"
  messages = session.get_messages
  messages.each do |evt|
    puts "  [#{evt.type}] #{evt.id}"
  end

  # ------------------------------------------------------------------
  # 5. Cleanup
  # ------------------------------------------------------------------

  unsub.call
  session.destroy
  puts "\nSession destroyed."

rescue StandardError => e
  puts "Error: #{e.class}: #{e.message}"
  puts e.backtrace&.first(5)&.join("\n")
ensure
  errors = client.stop
  unless errors.empty?
    puts "Cleanup errors:"
    errors.each { |err| puts "  - #{err.message}" }
  end
  puts "Client stopped."
end
