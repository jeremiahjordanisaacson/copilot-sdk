defmodule Copilot do
  @moduledoc """
  Elixir SDK for the GitHub Copilot CLI.

  This SDK communicates with the Copilot CLI server via JSON-RPC 2.0 over stdio.

  ## Quick start

      # Start a client (spawns the CLI process automatically)
      {:ok, client} = Copilot.Client.start_link()

      # Create a session
      {:ok, session} = Copilot.Client.create_session(client, %Copilot.Types.SessionConfig{
        model: "gpt-4"
      })

      # Subscribe to events
      Copilot.Session.on(session, fn event ->
        if event["type"] == "assistant.message" do
          IO.puts("Assistant: " <> event["data"]["content"])
        end
      end)

      # Send a message and wait for the response
      {:ok, response} = Copilot.Session.send_and_wait(session,
        %Copilot.Types.MessageOptions{prompt: "What is 2+2?"}
      )

      # Clean up
      Copilot.Session.destroy(session)
      Copilot.Client.stop(client)

  ## Modules

  - `Copilot.Client` - Main client GenServer; spawns CLI, manages sessions
  - `Copilot.Session` - Session GenServer; send messages, subscribe to events
  - `Copilot.JsonRpcClient` - Low-level JSON-RPC 2.0 transport over stdio
  - `Copilot.Types` - All type definitions as structs
  - `Copilot.DefineTool` - Helper for defining tools
  - `Copilot.SdkProtocolVersion` - Protocol version constant
  """
end
