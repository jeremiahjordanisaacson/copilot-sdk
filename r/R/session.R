#' CopilotSession
#'
#' Represents a single conversation session with the Copilot CLI.
#'
#' @description
#' A session maintains conversation state, handles events, and manages tool execution.
#' Sessions are created via \code{CopilotClient$create_session()} or resumed via
#' \code{CopilotClient$resume_session()}.
#'
#' @export
CopilotSession <- R6::R6Class(
  "CopilotSession",
  public = list(
    #' @field session_id Character. The unique identifier for this session.
    session_id = NULL,

    #' @field workspace_path Character or NULL. Path to workspace directory
    #'   when infinite sessions are enabled.
    workspace_path = NULL,

    #' @description Create a new CopilotSession.
    #'
    #' Note: This constructor is internal. Use CopilotClient$create_session()
    #' to create sessions.
    #'
    #' @param session_id Character. Session identifier.
    #' @param client JsonRpcClient R6 object.
    #' @param workspace_path Character or NULL.
    initialize = function(session_id, client, workspace_path = NULL) {
      self$session_id <- session_id
      self$workspace_path <- workspace_path
      private$client <- client
      private$event_handlers <- list()
      private$tool_handlers <- list()
      private$permission_handler <- NULL
      private$user_input_handler <- NULL
      private$hooks <- NULL
    },

    #' @description Send a message to this session.
    #'
    #' @param prompt Character. The prompt/message text to send.
    #' @param attachments List or NULL. Optional file/directory attachments.
    #' @param mode Character or NULL. "enqueue" or "immediate".
    #' @param response_format Character or NULL. Response format ("text", "image", or "json_object").
    #' @param image_options List or NULL. Image generation options (from \code{image_options()}).
    #'
    #' @return Character. The message ID of the response.
    send = function(prompt, attachments = NULL, mode = NULL,
                    response_format = NULL, image_options = NULL) {
      payload <- list(
        sessionId = self$session_id,
        prompt = prompt
      )
      if (!is.null(attachments)) payload$attachments <- attachments
      if (!is.null(mode)) payload$mode <- mode
      if (!is.null(response_format)) payload$responseFormat <- response_format
      if (!is.null(image_options)) payload$imageOptions <- image_options

      response <- private$client$request("session.send", payload)
      response$messageId
    },

    #' @description Send a message and wait until the session becomes idle.
    #'
    #' This is a convenience method that sends a message and then polls for
    #' events until session.idle is received. The event handlers registered
    #' via \code{on()} are still called for each event during the wait.
    #'
    #' @param prompt Character. The prompt/message text.
    #' @param attachments List or NULL. Optional attachments.
    #' @param mode Character or NULL. Processing mode.
    #' @param response_format Character or NULL. Response format ("text", "image", or "json_object").
    #' @param image_options List or NULL. Image generation options (from \code{image_options()}).
    #' @param timeout Numeric. Timeout in seconds (default 60).
    #'
    #' @return The last assistant.message SessionEvent, or NULL if none received.
    send_and_wait = function(prompt, attachments = NULL, mode = NULL,
                             response_format = NULL, image_options = NULL,
                             timeout = 60) {
      last_assistant_message <- NULL
      error_event <- NULL
      idle_received <- FALSE

      # Temporary event handler to track idle and messages
      temp_handler <- function(event) {
        if (identical(event$type, "assistant.message")) {
          last_assistant_message <<- event
        } else if (identical(event$type, "session.idle")) {
          idle_received <<- TRUE
        } else if (identical(event$type, "session.error")) {
          error_msg <- if (!is.null(event$data$message)) event$data$message else "Unknown error"
          error_event <<- paste0("Session error: ", error_msg)
          idle_received <<- TRUE
        }
      }

      unsubscribe <- self$on(temp_handler)
      on.exit(unsubscribe(), add = TRUE)

      # Send the message
      self$send(prompt = prompt, attachments = attachments, mode = mode,
                response_format = response_format, image_options = image_options)

      # Poll until idle or timeout
      start_time <- proc.time()[["elapsed"]]
      while (!idle_received) {
        elapsed <- proc.time()[["elapsed"]] - start_time
        if (elapsed > timeout) {
          stop(paste0("Timeout after ", timeout, "s waiting for session.idle"))
        }
        # Poll processes incoming messages (notifications, requests)
        private$client$poll(timeout_ms = 500L)
      }

      if (!is.null(error_event)) {
        stop(error_event)
      }

      last_assistant_message
    },

    #' @description Subscribe to events from this session.
    #'
    #' @param handler Function(event). Called with each SessionEvent.
    #'
    #' @return A function that when called, unsubscribes the handler.
    on = function(handler) {
      private$event_handlers <- c(private$event_handlers, list(handler))
      local_handler <- handler
      function() {
        private$event_handlers <- Filter(
          function(h) !identical(h, local_handler),
          private$event_handlers
        )
      }
    },

    #' @description Dispatch an event to all registered handlers.
    #' @param event SessionEvent R6 object.
    #' @keywords internal
    dispatch_event = function(event) {
      for (handler in private$event_handlers) {
        tryCatch(
          handler(event),
          error = function(e) {
            message(paste("Error in session event handler:", e$message))
          }
        )
      }
    },

    #' @description Register custom tool handlers.
    #' @param tools List of Tool R6 objects or NULL.
    #' @keywords internal
    register_tools = function(tools) {
      private$tool_handlers <- list()
      if (is.null(tools)) return(invisible(NULL))
      for (tool in tools) {
        if (!is.null(tool$name) && !is.null(tool$handler)) {
          private$tool_handlers[[tool$name]] <- tool$handler
        }
      }
    },

    #' @description Get a registered tool handler by name.
    #' @param name Character. Tool name.
    #' @return Function or NULL.
    #' @keywords internal
    get_tool_handler = function(name) {
      private$tool_handlers[[name]]
    },

    #' @description Register a permission request handler.
    #' @param handler Function or NULL.
    #' @keywords internal
    register_permission_handler = function(handler) {
      private$permission_handler <- handler
    },

    #' @description Handle a permission request from the CLI.
    #' @param request Named list. The permission request data.
    #' @return Named list with permission decision.
    #' @keywords internal
    handle_permission_request = function(request) {
      if (is.null(private$permission_handler)) {
        return(list(kind = "denied-no-approval-rule-and-could-not-request-from-user"))
      }

      tryCatch(
        {
          result <- private$permission_handler(
            request,
            list(session_id = self$session_id)
          )
          if (inherits(result, "PermissionRequestResult")) {
            result$to_list()
          } else {
            result
          }
        },
        error = function(e) {
          list(kind = "denied-no-approval-rule-and-could-not-request-from-user")
        }
      )
    },

    #' @description Register a user input handler.
    #' @param handler Function or NULL.
    #' @keywords internal
    register_user_input_handler = function(handler) {
      private$user_input_handler <- handler
    },

    #' @description Handle a user input request from the CLI.
    #' @param request Named list. The user input request data.
    #' @return Named list with answer and was_freeform.
    #' @keywords internal
    handle_user_input_request = function(request) {
      if (is.null(private$user_input_handler)) {
        stop("User input requested but no handler registered")
      }

      input_req <- UserInputRequest$new(
        question = request$question %||% "",
        choices = request$choices,
        allow_freeform = if (!is.null(request$allowFreeform)) request$allowFreeform else TRUE
      )

      result <- private$user_input_handler(
        input_req,
        list(session_id = self$session_id)
      )

      if (inherits(result, "UserInputResponse")) {
        list(answer = result$answer, was_freeform = result$was_freeform)
      } else {
        list(answer = result$answer, was_freeform = isTRUE(result$wasFreeform %||% result$was_freeform))
      }
    },

    #' @description Register hook handlers.
    #' @param hooks Named list of hook handler functions.
    #' @keywords internal
    register_hooks = function(hooks) {
      private$hooks <- hooks
    },

    #' @description Handle a hooks invocation from the CLI.
    #' @param hook_type Character. Hook type.
    #' @param input_data Any. Hook input.
    #' @return Hook output or NULL.
    #' @keywords internal
    handle_hooks_invoke = function(hook_type, input_data) {
      if (is.null(private$hooks)) return(NULL)

      handler_map <- list(
        preToolUse = private$hooks$on_pre_tool_use,
        postToolUse = private$hooks$on_post_tool_use,
        userPromptSubmitted = private$hooks$on_user_prompt_submitted,
        sessionStart = private$hooks$on_session_start,
        sessionEnd = private$hooks$on_session_end,
        errorOccurred = private$hooks$on_error_occurred
      )

      handler <- handler_map[[hook_type]]
      if (is.null(handler)) return(NULL)

      tryCatch(
        handler(input_data, list(session_id = self$session_id)),
        error = function(e) NULL
      )
    },

    #' @description Retrieve all events/messages from this session's history.
    #' @return A list of SessionEvent R6 objects.
    get_messages = function() {
      response <- private$client$request(
        "session.getMessages",
        list(sessionId = self$session_id)
      )
      events_dicts <- response$events %||% list()
      lapply(events_dicts, session_event_from_list)
    },

    #' @description Destroy this session and release resources.
    destroy = function() {
      private$client$request("session.destroy", list(sessionId = self$session_id))
      private$event_handlers <- list()
      private$tool_handlers <- list()
      private$permission_handler <- NULL
      private$user_input_handler <- NULL
      private$hooks <- NULL
      invisible(NULL)
    },

    #' @description Abort the currently processing message.
    abort = function() {
      private$client$request("session.abort", list(sessionId = self$session_id))
      invisible(NULL)
    }
  ),

  private = list(
    client = NULL,
    event_handlers = NULL,
    tool_handlers = NULL,
    permission_handler = NULL,
    user_input_handler = NULL,
    hooks = NULL
  )
)
