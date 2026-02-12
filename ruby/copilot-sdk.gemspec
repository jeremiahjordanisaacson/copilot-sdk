# frozen_string_literal: true

require_relative "lib/copilot/version"

Gem::Specification.new do |spec|
  spec.name          = "copilot-sdk"
  spec.version       = Copilot::VERSION
  spec.authors       = ["Microsoft Corporation"]
  spec.email         = ["copilot@github.com"]

  spec.summary       = "Ruby SDK for the GitHub Copilot CLI"
  spec.description   = <<~DESC
    A Ruby SDK for interacting with the GitHub Copilot CLI server via JSON-RPC 2.0.
    Provides session management, tool registration, permission handling, hooks,
    and event subscriptions over stdio or TCP transport.
  DESC
  spec.homepage      = "https://github.com/github/copilot-sdk"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/github/copilot-sdk/tree/main/ruby"
  spec.metadata["changelog_uri"]   = "https://github.com/github/copilot-sdk/blob/main/ruby/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*.rb",
    "LICENSE",
    "README.md",
  ]
  spec.require_paths = ["lib"]

  # No runtime dependencies - uses only Ruby stdlib (json, socket, open3, etc.)
end
