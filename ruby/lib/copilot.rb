# frozen_string_literal: true

# Copyright (c) Microsoft Corporation. All rights reserved.

require_relative "copilot/version"
require_relative "copilot/sdk_protocol_version"
require_relative "copilot/types"
require_relative "copilot/json_rpc_client"
require_relative "copilot/define_tool"
require_relative "copilot/session"
require_relative "copilot/client"

module Copilot
  # Convenience entry point.
  #
  # @example
  #   require "copilot"
  #
  #   client = Copilot::CopilotClient.new(cli_path: "/usr/local/bin/copilot")
  #   client.start
  #
  #   session = client.create_session(model: "gpt-4")
  #   response = session.send_and_wait(prompt: "Hello!")
  #   puts response&.data&.dig("content")
  #
  #   session.destroy
  #   client.stop
end
