# frozen_string_literal: true

# Copyright (c) Microsoft Corporation. All rights reserved.

module Copilot
  # Helper for defining tools with a concise DSL.
  #
  # @example
  #   weather_tool = Copilot.define_tool(
  #     name: "get_weather",
  #     description: "Get weather for a location",
  #     parameters: {
  #       type: "object",
  #       properties: {
  #         location: { type: "string", description: "City name" },
  #         unit:     { type: "string", enum: ["celsius", "fahrenheit"] }
  #       },
  #       required: ["location"]
  #     }
  #   ) do |args, invocation|
  #     location = args["location"] || args[:location]
  #     "Weather in #{location}: 22 degrees, sunny"
  #   end
  #
  # @param name        [String]    tool name
  # @param description [String]    human-readable description
  # @param parameters  [Hash, nil] JSON Schema for the tool parameters
  # @yield [args, invocation] called when the tool is invoked
  # @yieldparam args       [Hash]           parsed arguments from the LLM
  # @yieldparam invocation [ToolInvocation]  context about the invocation
  # @yieldreturn [String, Hash, ToolResult] the tool result
  # @return [Tool]
  def self.define_tool(name:, description: nil, parameters: nil, &handler)
    raise ArgumentError, "Block required for tool handler" unless handler

    Tool.new(
      name: name,
      description: description,
      parameters: parameters,
      handler: handler
    )
  end

  # Normalize a tool handler's return value into a wire-format Hash.
  #
  # - +nil+ is treated as a failure (no result).
  # - +String+ is wrapped as a successful text result.
  # - +ToolResult+ is converted via +to_h+.
  # - +Hash+ with +textResultForLlm+ key passes through (duck-typed ToolResultObject).
  # - Any other value is JSON-serialized as a successful text result.
  #
  # @param result [Object] the raw handler return value
  # @return [Hash] normalized wire-format tool result
  def self.normalize_tool_result(result)
    if result.nil?
      return {
        textResultForLlm: "Tool returned no result",
        resultType: ToolResultType::FAILURE,
        error: "tool returned no result",
        toolTelemetry: {},
      }
    end

    # ToolResult struct
    if result.is_a?(ToolResult)
      return result.to_h
    end

    # Hash that looks like a ToolResultObject (duck-type check)
    if result.is_a?(Hash) && (result.key?(:textResultForLlm) || result.key?("textResultForLlm"))
      return result
    end

    # String passes through as success
    text = result.is_a?(String) ? result : JSON.generate(result)
    {
      textResultForLlm: text,
      resultType: ToolResultType::SUCCESS,
      toolTelemetry: {},
    }
  end
end
