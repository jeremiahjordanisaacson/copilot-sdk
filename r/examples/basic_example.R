# Basic Example for the Copilot R SDK
#
# This example demonstrates:
# 1. Creating a CopilotClient and starting the CLI server
# 2. Defining a custom tool
# 3. Creating a session with the tool
# 4. Sending messages and receiving events
# 5. Using send_and_wait for synchronous interaction
# 6. Cleaning up

library(copilot.sdk)

# --- Define a custom tool ---------------------------------------------------

facts <- list(
  r = "R was created in 1993 by Ross Ihaka and Robert Gentleman at the University of Auckland.",
  python = "Python was created in 1991 by Guido van Rossum.",
  javascript = "JavaScript was created in 10 days by Brendan Eich in 1995.",
  node = "Node.js lets you run JavaScript outside the browser using the V8 engine."
)

lookup_fact_tool <- define_tool(
  name = "lookup_fact",
  description = "Returns a fun fact about a given programming topic.",
  parameters = list(
    type = "object",
    properties = list(
      topic = list(
        type = "string",
        description = "Topic to look up (e.g. 'r', 'python', 'javascript', 'node')"
      )
    ),
    required = list("topic")
  ),
  handler = function(invocation) {
    topic <- tolower(invocation$arguments$topic)
    fact <- facts[[topic]]
    if (is.null(fact)) {
      paste0("No fact stored for '", topic, "'.")
    } else {
      fact
    }
  }
)


# --- Create the client -------------------------------------------------------

cat("Starting Copilot SDK Example\n\n")

# Create client - will spawn the CLI process in headless stdio mode
client <- CopilotClient$new(log_level = "info")
client$start()
cat("Client started and connected.\n")

# --- Create a session with the tool ------------------------------------------

session <- client$create_session(tools = list(lookup_fact_tool))
cat(sprintf("Session created: %s\n\n", session$session_id))

# --- Subscribe to events -----------------------------------------------------

unsubscribe <- session$on(function(event) {
  cat(sprintf("Event [%s]: ", event$type))
  if (identical(event$type, "assistant.message") && !is.null(event$data$content)) {
    cat(event$data$content)
  } else if (identical(event$type, "tool.execution_start")) {
    cat(sprintf("Running tool: %s", event$data$toolName %||% "unknown"))
  } else if (identical(event$type, "tool.execution_complete")) {
    cat("Tool completed")
  } else if (identical(event$type, "session.idle")) {
    cat("Session idle")
  } else if (identical(event$type, "session.error")) {
    cat(sprintf("Error: %s", event$data$message %||% "unknown"))
  }
  cat("\n")
})

# --- Send a simple message ---------------------------------------------------

cat("Sending message: 'Tell me 2+2'\n")
result1 <- session$send_and_wait(prompt = "Tell me 2+2")
if (!is.null(result1)) {
  cat(sprintf("\nResponse: %s\n\n", result1$data$content))
}

# --- Send a message that uses the custom tool --------------------------------

cat("Sending message: 'Use lookup_fact to tell me about R'\n")
result2 <- session$send_and_wait(prompt = "Use lookup_fact to tell me about 'r'")
if (!is.null(result2)) {
  cat(sprintf("\nResponse: %s\n\n", result2$data$content))
}

# --- List available models ---------------------------------------------------

cat("Listing available models:\n")
tryCatch(
  {
    models <- client$list_models()
    for (m in models) {
      cat(sprintf("  - %s (%s)\n", m$id, m$name))
    }
  },
  error = function(e) {
    cat(sprintf("  Could not list models: %s\n", e$message))
  }
)

# --- Cleanup -----------------------------------------------------------------

unsubscribe()
session$destroy()
errors <- client$stop()
if (length(errors) > 0) {
  cat("Cleanup errors:\n")
  for (err in errors) cat(sprintf("  - %s\n", err))
} else {
  cat("\nDone! Cleanup successful.\n")
}
