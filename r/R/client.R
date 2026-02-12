#' CopilotClient
#'
#' Main client for interacting with the GitHub Copilot CLI.
#'
#' @description
#' The CopilotClient manages the connection to the Copilot CLI server and provides
#' methods to create and manage conversation sessions. It spawns the CLI server
#' as a subprocess communicating via JSON-RPC 2.0 over stdio.
#'
#' @export
CopilotClient <- R6::R6Class(
  "CopilotClient",
  public = list(
    #' @field options Named list of client options.
    options = NULL,

    #' @description Create a new CopilotClient.
    #'
    #' @param cli_path Character. Path to the Copilot CLI executable.
    #'   Default: "copilot" (found via PATH).
    #' @param cwd Character. Working directory for the CLI process.
    #'   Default: current working directory.
    #' @param log_level Character. Log level ("none","error","warning","info","debug","all").
    #'   Default: "info".
    #' @param auto_start Logical. Auto-start CLI on first use. Default: TRUE.
    #' @param github_token Character or NULL. GitHub token for authentication.
    #' @param use_logged_in_user Logical. Use stored OAuth / gh CLI auth.
    #'   Default: TRUE (but FALSE when github_token is provided).
    #' @param env Named list or NULL. Additional environment variables.
    #'
    #' @return A CopilotClient R6 object.
    #'
    #' @examples
    #' \dontrun{
    #' client <- CopilotClient$new()
    #' client$start()
    #' session <- client$create_session()
    #' }
    initialize = function(cli_path = NULL, cwd = getwd(), log_level = "info",
                          auto_start = TRUE, github_token = NULL,
                          use_logged_in_user = NULL, env = NULL) {
      # Determine CLI path
      if (is.null(cli_path)) {
        cli_path <- Sys.which("copilot")
        if (nchar(cli_path) == 0) {
          cli_path <- "copilot"
        }
      }

      # Default use_logged_in_user
      if (is.null(use_logged_in_user)) {
        use_logged_in_user <- is.null(github_token)
      }

      self$options <- list(
        cli_path = cli_path,
        cwd = cwd,
        log_level = log_level,
        auto_start = auto_start,
        github_token = github_token,
        use_logged_in_user = use_logged_in_user,
        env = env
      )

      private$process <- NULL
      private$client <- NULL
      private$state <- "disconnected"
      private$sessions <- new.env(parent = emptyenv())
      private$models_cache <- NULL
      private$lifecycle_handlers <- list()
    },

    #' @description Start the CLI server and establish connection.
    #'
    #' Spawns the Copilot CLI subprocess and connects via stdio.
    #' Verifies protocol version compatibility via ping.
    #'
    #' @return Invisible self.
    start = function() {
      if (private$state == "connected") return(invisible(self))

      private$state <- "connecting"

      tryCatch(
        {
          private$start_cli_server()
          private$connect_to_server()
          private$verify_protocol_version()
          private$state <- "connected"
        },
        error = function(e) {
          private$state <- "error"
          stop(e)
        }
      )

      invisible(self)
    },

    #' @description Stop the CLI server and close all sessions.
    #'
    #' @return A list of error messages that occurred during cleanup (empty if all ok).
    stop = function() {
      errors <- character(0)

      # Destroy all sessions
      session_ids <- ls(private$sessions)
      for (sid in session_ids) {
        tryCatch(
          {
            session <- get(sid, envir = private$sessions)
            session$destroy()
          },
          error = function(e) {
            errors <<- c(errors, paste0("Failed to destroy session ", sid, ": ", e$message))
          }
        )
      }
      # Clear sessions
      rm(list = ls(private$sessions), envir = private$sessions)

      # Stop client
      if (!is.null(private$client)) {
        private$client$stop()
        private$client <- NULL
      }

      # Clear models cache
      private$models_cache <- NULL

      # Kill CLI process
      if (!is.null(private$process)) {
        tryCatch(
          {
            if (private$process$is_alive()) {
              private$process$signal(tools::SIGTERM)
              private$process$wait(timeout = 5000)
            }
          },
          error = function(e) {
            tryCatch(private$process$kill(), error = function(e2) NULL)
          }
        )
        private$process <- NULL
      }

      private$state <- "disconnected"
      errors
    },

    #' @description Force stop without graceful cleanup.
    force_stop = function() {
      rm(list = ls(private$sessions), envir = private$sessions)

      if (!is.null(private$client)) {
        tryCatch(private$client$stop(), error = function(e) NULL)
        private$client <- NULL
      }

      private$models_cache <- NULL

      if (!is.null(private$process)) {
        tryCatch(private$process$kill(), error = function(e) NULL)
        private$process <- NULL
      }

      private$state <- "disconnected"
      invisible(NULL)
    },

    #' @description Get the current connection state.
    #' @return Character: "disconnected", "connecting", "connected", or "error".
    get_state = function() {
      private$state
    },

    #' @description Create a new conversation session.
    #'
    #' @param model Character or NULL. Model to use (e.g. "gpt-5").
    #' @param session_id Character or NULL. Custom session ID.
    #' @param tools List of Tool R6 objects or NULL.
    #' @param system_message Named list or NULL. System message config.
    #' @param streaming Logical or NULL. Enable streaming delta events.
    #' @param available_tools Character vector or NULL. Tool names to allow.
    #' @param excluded_tools Character vector or NULL. Tool names to exclude.
    #' @param on_permission_request Function or NULL. Permission request handler.
    #' @param on_user_input_request Function or NULL. User input handler.
    #' @param hooks Named list or NULL. Hook handlers.
    #' @param working_directory Character or NULL. Working directory for session.
    #' @param provider Named list or NULL. Custom provider config (BYOK).
    #' @param mcp_servers Named list or NULL. MCP server configurations.
    #' @param config_dir Character or NULL. Override config directory.
    #' @param infinite_sessions Named list or NULL. Infinite session config.
    #'
    #' @return A CopilotSession R6 object.
    create_session = function(model = NULL, session_id = NULL, tools = NULL,
                              system_message = NULL, streaming = NULL,
                              available_tools = NULL, excluded_tools = NULL,
                              on_permission_request = NULL,
                              on_user_input_request = NULL,
                              hooks = NULL, working_directory = NULL,
                              provider = NULL, mcp_servers = NULL,
                              config_dir = NULL, infinite_sessions = NULL) {
      if (is.null(private$client)) {
        if (isTRUE(self$options$auto_start)) {
          self$start()
        } else {
          stop("Client not connected. Call start() first.")
        }
      }

      # Build tool definitions for the wire
      tool_defs <- list()
      if (!is.null(tools)) {
        for (tool in tools) {
          defn <- list(name = tool$name, description = tool$description)
          if (!is.null(tool$parameters)) defn$parameters <- tool$parameters
          tool_defs <- c(tool_defs, list(defn))
        }
      }

      # Build payload
      payload <- list()
      if (!is.null(model)) payload$model <- model
      if (!is.null(session_id)) payload$sessionId <- session_id
      if (length(tool_defs) > 0) payload$tools <- tool_defs
      if (!is.null(system_message)) payload$systemMessage <- system_message
      if (!is.null(available_tools)) payload$availableTools <- available_tools
      if (!is.null(excluded_tools)) payload$excludedTools <- excluded_tools
      if (!is.null(on_permission_request)) payload$requestPermission <- TRUE
      if (!is.null(on_user_input_request)) payload$requestUserInput <- TRUE
      if (!is.null(hooks) && length(hooks) > 0) payload$hooks <- TRUE
      if (!is.null(working_directory)) payload$workingDirectory <- working_directory
      if (!is.null(streaming)) payload$streaming <- streaming
      if (!is.null(provider)) payload$provider <- private$convert_provider(provider)
      if (!is.null(mcp_servers)) payload$mcpServers <- mcp_servers
      if (!is.null(config_dir)) payload$configDir <- config_dir
      if (!is.null(infinite_sessions)) {
        wire_config <- list()
        if (!is.null(infinite_sessions$enabled)) wire_config$enabled <- infinite_sessions$enabled
        if (!is.null(infinite_sessions$background_compaction_threshold)) {
          wire_config$backgroundCompactionThreshold <- infinite_sessions$background_compaction_threshold
        }
        if (!is.null(infinite_sessions$buffer_exhaustion_threshold)) {
          wire_config$bufferExhaustionThreshold <- infinite_sessions$buffer_exhaustion_threshold
        }
        payload$infiniteSessions <- wire_config
      }

      response <- private$client$request("session.create", payload)

      sid <- response$sessionId
      workspace_path <- response$workspacePath

      session <- CopilotSession$new(sid, private$client, workspace_path)

      # Register tools
      if (!is.null(tools)) {
        session$register_tools(tools)
      }
      if (!is.null(on_permission_request)) {
        session$register_permission_handler(on_permission_request)
      }
      if (!is.null(on_user_input_request)) {
        session$register_user_input_handler(on_user_input_request)
      }
      if (!is.null(hooks)) {
        session$register_hooks(hooks)
      }

      assign(sid, session, envir = private$sessions)
      session
    },

    #' @description Resume an existing session by ID.
    #'
    #' @param session_id Character. The session ID to resume.
    #' @param model Character or NULL. Override model.
    #' @param tools List of Tool R6 objects or NULL.
    #' @param system_message Named list or NULL.
    #' @param streaming Logical or NULL.
    #' @param on_permission_request Function or NULL.
    #' @param on_user_input_request Function or NULL.
    #' @param hooks Named list or NULL.
    #' @param working_directory Character or NULL.
    #' @param provider Named list or NULL.
    #' @param disable_resume Logical or NULL.
    #'
    #' @return A CopilotSession R6 object.
    resume_session = function(session_id, model = NULL, tools = NULL,
                              system_message = NULL, streaming = NULL,
                              on_permission_request = NULL,
                              on_user_input_request = NULL,
                              hooks = NULL, working_directory = NULL,
                              provider = NULL, disable_resume = NULL) {
      if (is.null(private$client)) {
        if (isTRUE(self$options$auto_start)) {
          self$start()
        } else {
          stop("Client not connected. Call start() first.")
        }
      }

      tool_defs <- list()
      if (!is.null(tools)) {
        for (tool in tools) {
          defn <- list(name = tool$name, description = tool$description)
          if (!is.null(tool$parameters)) defn$parameters <- tool$parameters
          tool_defs <- c(tool_defs, list(defn))
        }
      }

      payload <- list(sessionId = session_id)
      if (!is.null(model)) payload$model <- model
      if (length(tool_defs) > 0) payload$tools <- tool_defs
      if (!is.null(system_message)) payload$systemMessage <- system_message
      if (!is.null(streaming)) payload$streaming <- streaming
      if (!is.null(on_permission_request)) payload$requestPermission <- TRUE
      if (!is.null(on_user_input_request)) payload$requestUserInput <- TRUE
      if (!is.null(hooks) && length(hooks) > 0) payload$hooks <- TRUE
      if (!is.null(working_directory)) payload$workingDirectory <- working_directory
      if (!is.null(provider)) payload$provider <- private$convert_provider(provider)
      if (isTRUE(disable_resume)) payload$disableResume <- TRUE

      response <- private$client$request("session.resume", payload)

      sid <- response$sessionId
      workspace_path <- response$workspacePath

      session <- CopilotSession$new(sid, private$client, workspace_path)
      if (!is.null(tools)) session$register_tools(tools)
      if (!is.null(on_permission_request)) session$register_permission_handler(on_permission_request)
      if (!is.null(on_user_input_request)) session$register_user_input_handler(on_user_input_request)
      if (!is.null(hooks)) session$register_hooks(hooks)

      assign(sid, session, envir = private$sessions)
      session
    },

    #' @description Send a ping to verify connectivity.
    #' @param message Character or NULL. Optional message.
    #' @return A PingResponse R6 object.
    ping = function(message = NULL) {
      if (is.null(private$client)) stop("Client not connected")
      result <- private$client$request("ping", list(message = message))
      ping_response_from_list(result)
    },

    #' @description List available models.
    #' @return A list of ModelInfo R6 objects.
    list_models = function() {
      if (is.null(private$client)) stop("Client not connected")

      # Return cached if available
      if (!is.null(private$models_cache)) return(private$models_cache)

      response <- private$client$request("models.list", list())
      models_data <- response$models %||% list()
      models <- lapply(models_data, model_info_from_list)
      private$models_cache <- models
      models
    },

    #' @description List all sessions known to the server.
    #' @return A list of SessionMetadata R6 objects.
    list_sessions = function() {
      if (is.null(private$client)) stop("Client not connected")
      response <- private$client$request("session.list", list())
      sessions_data <- response$sessions %||% list()
      lapply(sessions_data, session_metadata_from_list)
    },

    #' @description Delete a session permanently.
    #' @param session_id Character. Session ID to delete.
    delete_session = function(session_id) {
      if (is.null(private$client)) stop("Client not connected")
      response <- private$client$request("session.delete", list(sessionId = session_id))
      if (!isTRUE(response$success)) {
        err <- response$error %||% "Unknown error"
        stop(paste0("Failed to delete session ", session_id, ": ", err))
      }
      # Remove from local map
      if (exists(session_id, envir = private$sessions)) {
        rm(list = session_id, envir = private$sessions)
      }
      invisible(NULL)
    },

    #' @description Subscribe to session lifecycle events.
    #' @param handler Function(SessionLifecycleEvent).
    #' @return A function that when called, unsubscribes the handler.
    on = function(handler) {
      private$lifecycle_handlers <- c(private$lifecycle_handlers, list(handler))
      local_handler <- handler
      function() {
        private$lifecycle_handlers <- Filter(
          function(h) !identical(h, local_handler),
          private$lifecycle_handlers
        )
      }
    },

    #' @description Poll for and process incoming messages.
    #'
    #' Call this periodically (e.g. in a loop or via later/shiny reactive)
    #' to process incoming notifications and requests from the CLI server.
    #'
    #' @param timeout_ms Integer. Poll timeout in milliseconds.
    #' @return Logical. TRUE if a message was processed.
    poll = function(timeout_ms = 100L) {
      if (is.null(private$client)) return(FALSE)
      private$client$poll(timeout_ms)
    }
  ),

  private = list(
    process = NULL,
    client = NULL,
    state = "disconnected",
    sessions = NULL,
    models_cache = NULL,
    lifecycle_handlers = NULL,

    start_cli_server = function() {
      cli_path <- self$options$cli_path

      args <- c("--headless", "--no-auto-update",
                "--log-level", self$options$log_level,
                "--stdio")

      # Auth flags
      if (!is.null(self$options$github_token)) {
        args <- c(args, "--auth-token-env", "COPILOT_SDK_AUTH_TOKEN")
      }
      if (!isTRUE(self$options$use_logged_in_user)) {
        args <- c(args, "--no-auto-login")
      }

      # Build environment
      env <- Sys.getenv()
      if (!is.null(self$options$env)) {
        for (nm in names(self$options$env)) {
          env[[nm]] <- self$options$env[[nm]]
        }
      }
      if (!is.null(self$options$github_token)) {
        env[["COPILOT_SDK_AUTH_TOKEN"]] <- self$options$github_token
      }

      # Convert env to character vector "KEY=VALUE"
      env_vec <- paste0(names(env), "=", unname(env))

      # Determine if cli_path is a .js file
      if (grepl("\\.js$", cli_path)) {
        command <- "node"
        args <- c(cli_path, args)
      } else {
        command <- cli_path
      }

      private$process <- processx::process$new(
        command = command,
        args = args,
        stdin = "|",
        stdout = "|",
        stderr = "|",
        env = env_vec,
        wd = self$options$cwd,
        cleanup = TRUE,
        cleanup_tree = TRUE
      )

      if (!private$process$is_alive()) {
        stop("Failed to start CLI process")
      }
    },

    connect_to_server = function() {
      private$client <- JsonRpcClient$new(private$process)

      # Set up notification handler
      private$client$set_notification_handler(function(method, params) {
        if (identical(method, "session.event")) {
          session_id <- params$sessionId
          event_dict <- params$event
          event <- session_event_from_list(event_dict)
          if (exists(session_id, envir = private$sessions)) {
            session <- get(session_id, envir = private$sessions)
            session$dispatch_event(event)
          }
        } else if (identical(method, "session.lifecycle")) {
          lifecycle_event <- session_lifecycle_event_from_list(params)
          private$dispatch_lifecycle_event(lifecycle_event)
        }
      })

      # Set up request handlers for tool.call, permission.request, etc.
      private$client$set_request_handler("tool.call", function(params) {
        private$handle_tool_call(params)
      })

      private$client$set_request_handler("permission.request", function(params) {
        private$handle_permission_request(params)
      })

      private$client$set_request_handler("userInput.request", function(params) {
        private$handle_user_input_request(params)
      })

      private$client$set_request_handler("hooks.invoke", function(params) {
        private$handle_hooks_invoke(params)
      })

      private$client$start()
    },

    verify_protocol_version = function() {
      expected <- get_sdk_protocol_version()
      ping_result <- self$ping()
      server_version <- ping_result$protocol_version

      if (is.null(server_version)) {
        stop(paste0(
          "SDK protocol version mismatch: SDK expects version ", expected,
          ", but server does not report a protocol version. ",
          "Please update your server to ensure compatibility."
        ))
      }

      if (server_version != expected) {
        stop(paste0(
          "SDK protocol version mismatch: SDK expects version ", expected,
          ", but server reports version ", server_version, ". ",
          "Please update your SDK or server to ensure compatibility."
        ))
      }
    },

    convert_provider = function(provider) {
      wire <- list(type = provider$type)
      if (!is.null(provider$base_url)) wire$baseUrl <- provider$base_url
      if (!is.null(provider$api_key)) wire$apiKey <- provider$api_key
      if (!is.null(provider$wire_api)) wire$wireApi <- provider$wire_api
      if (!is.null(provider$bearer_token)) wire$bearerToken <- provider$bearer_token
      if (!is.null(provider$azure)) {
        wire_azure <- list()
        if (!is.null(provider$azure$api_version)) wire_azure$apiVersion <- provider$azure$api_version
        wire$azure <- wire_azure
      }
      wire
    },

    dispatch_lifecycle_event = function(event) {
      for (handler in private$lifecycle_handlers) {
        tryCatch(handler(event), error = function(e) NULL)
      }
    },

    handle_tool_call = function(params) {
      session_id <- params$sessionId
      tool_call_id <- params$toolCallId
      tool_name <- params$toolName

      if (is.null(session_id) || is.null(tool_call_id) || is.null(tool_name)) {
        stop("Invalid tool call payload")
      }

      if (!exists(session_id, envir = private$sessions)) {
        stop(paste0("Unknown session ", session_id))
      }

      session <- get(session_id, envir = private$sessions)
      handler <- session$get_tool_handler(tool_name)

      if (is.null(handler)) {
        return(list(result = list(
          textResultForLlm = paste0("Tool '", tool_name, "' is not supported."),
          resultType = "failure",
          error = paste0("tool '", tool_name, "' not supported"),
          toolTelemetry = list()
        )))
      }

      invocation <- ToolInvocation$new(
        session_id = session_id,
        tool_call_id = tool_call_id,
        tool_name = tool_name,
        arguments = params$arguments
      )

      result <- tryCatch(
        {
          res <- handler(invocation)
          if (is.null(res)) {
            list(
              textResultForLlm = "Tool returned no result.",
              resultType = "failure",
              error = "tool returned no result",
              toolTelemetry = list()
            )
          } else if (inherits(res, "ToolResultObject")) {
            res$to_list()
          } else if (is.list(res) && !is.null(res$textResultForLlm)) {
            res
          } else if (is.character(res)) {
            list(textResultForLlm = res, resultType = "success")
          } else {
            list(
              textResultForLlm = jsonlite::toJSON(res, auto_unbox = TRUE),
              resultType = "success"
            )
          }
        },
        error = function(e) {
          list(
            textResultForLlm = "Invoking this tool produced an error. Detailed information is not available.",
            resultType = "failure",
            error = e$message,
            toolTelemetry = list()
          )
        }
      )

      list(result = result)
    },

    handle_permission_request = function(params) {
      session_id <- params$sessionId
      permission_request <- params$permissionRequest

      if (is.null(session_id) || is.null(permission_request)) {
        stop("Invalid permission request payload")
      }

      if (!exists(session_id, envir = private$sessions)) {
        stop(paste0("Unknown session ", session_id))
      }

      session <- get(session_id, envir = private$sessions)

      tryCatch(
        {
          result <- session$handle_permission_request(permission_request)
          list(result = result)
        },
        error = function(e) {
          list(result = list(kind = "denied-no-approval-rule-and-could-not-request-from-user"))
        }
      )
    },

    handle_user_input_request = function(params) {
      session_id <- params$sessionId
      question <- params$question

      if (is.null(session_id) || is.null(question)) {
        stop("Invalid user input request payload")
      }

      if (!exists(session_id, envir = private$sessions)) {
        stop(paste0("Unknown session ", session_id))
      }

      session <- get(session_id, envir = private$sessions)
      result <- session$handle_user_input_request(params)
      list(answer = result$answer, wasFreeform = result$was_freeform)
    },

    handle_hooks_invoke = function(params) {
      session_id <- params$sessionId
      hook_type <- params$hookType
      input_data <- params$input

      if (is.null(session_id) || is.null(hook_type)) {
        stop("Invalid hooks invoke payload")
      }

      if (!exists(session_id, envir = private$sessions)) {
        stop(paste0("Unknown session ", session_id))
      }

      session <- get(session_id, envir = private$sessions)
      output <- session$handle_hooks_invoke(hook_type, input_data)
      list(output = output)
    }
  )
)
