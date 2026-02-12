# Basic example of using the Copilot SDK for Elixir
#
# Prerequisites:
#   1. Install deps: mix deps.get
#   2. Ensure the `copilot` CLI is on your PATH (or set :cli_path)
#   3. Authenticate: copilot auth login
#
# Run:
#   mix run examples/basic_example.exs

alias Copilot.Client
alias Copilot.Session
alias Copilot.DefineTool
alias Copilot.Types.{CopilotClientOptions, SessionConfig, MessageOptions}

# --------------------------------------------------------------------------
# Define a custom tool
# --------------------------------------------------------------------------

facts = %{
  "javascript" => "JavaScript was created in 10 days by Brendan Eich in 1995.",
  "node" => "Node.js lets you run JavaScript outside the browser using the V8 engine.",
  "elixir" => "Elixir was created by Jose Valim in 2011 and runs on the BEAM VM."
}

lookup_fact_tool =
  DefineTool.define("lookup_fact",
    description: "Returns a fun fact about a given topic.",
    parameters: %{
      "type" => "object",
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "description" => "Topic to look up (e.g. 'javascript', 'node', 'elixir')"
        }
      },
      "required" => ["topic"]
    },
    handler: fn %{"topic" => topic}, _invocation ->
      Map.get(facts, String.downcase(topic), "No fact stored for #{topic}.")
    end
  )

# --------------------------------------------------------------------------
# Start the client
# --------------------------------------------------------------------------

IO.puts("Starting Copilot SDK Example...\n")

{:ok, client} =
  Client.start_link(%CopilotClientOptions{
    log_level: "info"
  })

# Start the CLI server explicitly (or let auto_start handle it)
:ok = Client.start(client)
IO.puts("Client connected.\n")

# --------------------------------------------------------------------------
# Create a session with the tool
# --------------------------------------------------------------------------

{:ok, session} =
  Client.create_session(client, %SessionConfig{
    tools: [lookup_fact_tool]
  })

sid = Session.session_id(session)
IO.puts("Session created: #{sid}\n")

# --------------------------------------------------------------------------
# Subscribe to all events
# --------------------------------------------------------------------------

Session.on(session, fn event ->
  type = event["type"]

  case type do
    "assistant.message" ->
      IO.puts("[Event] assistant.message: #{event["data"]["content"]}")

    "tool.execution_start" ->
      IO.puts("[Event] tool.execution_start: #{event["data"]["toolName"]}")

    "tool.execution_complete" ->
      IO.puts("[Event] tool.execution_complete: success=#{event["data"]["success"]}")

    "session.idle" ->
      IO.puts("[Event] session.idle")

    _ ->
      IO.puts("[Event] #{type}")
  end
end)

# --------------------------------------------------------------------------
# Send a simple message
# --------------------------------------------------------------------------

IO.puts("\nSending message: 'Tell me 2+2'")

case Session.send_and_wait(session, %MessageOptions{prompt: "Tell me 2+2"}) do
  {:ok, nil} ->
    IO.puts("Response: (no assistant message)")

  {:ok, response} ->
    IO.puts("Response: #{response["data"]["content"]}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

# --------------------------------------------------------------------------
# Send a message that uses the tool
# --------------------------------------------------------------------------

IO.puts("\nSending message: 'Use lookup_fact to tell me about elixir'")

case Session.send_and_wait(
       session,
       %MessageOptions{prompt: "Use lookup_fact to tell me about 'elixir'"}
     ) do
  {:ok, nil} ->
    IO.puts("Response: (no assistant message)")

  {:ok, response} ->
    IO.puts("Response: #{response["data"]["content"]}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

# --------------------------------------------------------------------------
# Clean up
# --------------------------------------------------------------------------

Session.destroy(session)
Client.stop(client)
IO.puts("\nDone!")
