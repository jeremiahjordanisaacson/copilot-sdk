#' JSON-RPC 2.0 Client for stdio transport
#'
#' Minimal JSON-RPC 2.0 client that communicates with the Copilot CLI server
#' via Content-Length header framing over stdio (stdin/stdout of a subprocess).
#'
#' Uses processx::process for subprocess management and a background read loop
#' via callr/later for async message handling within an R polling loop.

#' JsonRpcError
#'
#' Custom error condition for JSON-RPC error responses.
#'
#' @param code Integer. JSON-RPC error code.
#' @param message Character. Error message.
#' @param data Any. Additional error data.
#' @keywords internal
json_rpc_error <- function(code, message, data = NULL) {
  structure(
    class = c("json_rpc_error", "error", "condition"),
    list(
      message = paste0("JSON-RPC Error ", code, ": ", message),
      code = code,
      rpc_message = message,
      data = data
    )
  )
}


#' JsonRpcClient
#'
#' JSON-RPC 2.0 client for stdio transport with Content-Length header framing.
#'
#' @description
#' This client communicates with a subprocess over stdin/stdout using the
#' JSON-RPC 2.0 protocol with Content-Length header framing (the same protocol
#' used by the Language Server Protocol).
#'
#' @export
JsonRpcClient <- R6::R6Class(
  "JsonRpcClient",
  public = list(
    #' @field process The processx::process object.
    process = NULL,

    #' @description Create a new JsonRpcClient.
    #' @param process A processx::process object with stdin/stdout pipes.
    initialize = function(process) {
      self$process <- process
      private$pending_requests <- new.env(parent = emptyenv())
      private$notification_handler <- NULL
      private$request_handlers <- list()
      private$running <- FALSE
      private$write_lock <- FALSE
      private$next_id <- 1L
      private$read_buffer <- raw(0)
    },

    #' @description Start listening for messages in a background polling loop.
    start = function() {
      if (!private$running) {
        private$running <- TRUE
      }
    },

    #' @description Stop listening and clean up.
    stop = function() {
      private$running <- FALSE
    },

    #' @description Send a JSON-RPC request and wait for response (blocking).
    #' @param method Character. Method name.
    #' @param params Named list or NULL. Parameters.
    #' @param timeout Numeric. Timeout in seconds (default 60).
    #' @return The result from the response.
    request = function(method, params = list(), timeout = 60) {
      request_id <- private$new_id()

      message <- list(
        jsonrpc = "2.0",
        id = request_id,
        method = method,
        params = params
      )

      private$send_message(message)

      # Blocking wait: poll stdout until we get the response for this request_id
      start_time <- proc.time()[["elapsed"]]
      result <- NULL
      error <- NULL
      got_response <- FALSE

      while (!got_response) {
        elapsed <- proc.time()[["elapsed"]] - start_time
        if (elapsed > timeout) {
          stop(paste0("JSON-RPC request timed out after ", timeout, "s for method: ", method))
        }

        msg <- private$read_message(timeout_ms = 1000L)
        if (is.null(msg)) {
          # Check if process is still alive
          if (!self$process$is_alive()) {
            stop("CLI process exited unexpectedly")
          }
          next
        }

        # Check if this is the response we're waiting for
        if (!is.null(msg$id) && identical(msg$id, request_id)) {
          if (!is.null(msg$error)) {
            err <- msg$error
            stop(json_rpc_error(
              code = err$code %||% -1L,
              message = err$message %||% "Unknown error",
              data = err$data
            ))
          }
          result <- msg$result
          got_response <- TRUE
        } else {
          # It's a notification or request from server -- handle it
          private$handle_incoming(msg)
        }
      }

      result
    },

    #' @description Send a JSON-RPC notification (no response expected).
    #' @param method Character. Method name.
    #' @param params Named list or NULL.
    notify = function(method, params = list()) {
      message <- list(
        jsonrpc = "2.0",
        method = method,
        params = params
      )
      private$send_message(message)
    },

    #' @description Set handler for incoming notifications from server.
    #' @param handler Function(method, params) or NULL.
    set_notification_handler = function(handler) {
      private$notification_handler <- handler
    },

    #' @description Set handler for incoming requests from server.
    #' @param method Character. The method name to handle.
    #' @param handler Function(params) returning a named list, or NULL to remove.
    set_request_handler = function(method, handler) {
      if (is.null(handler)) {
        private$request_handlers[[method]] <- NULL
      } else {
        private$request_handlers[[method]] <- handler
      }
    },

    #' @description Poll and process any pending incoming messages.
    #' @param timeout_ms Integer. Poll timeout in milliseconds.
    #' @return Logical. TRUE if a message was processed.
    poll = function(timeout_ms = 100L) {
      msg <- private$read_message(timeout_ms = timeout_ms)
      if (!is.null(msg)) {
        private$handle_incoming(msg)
        return(TRUE)
      }
      return(FALSE)
    }
  ),

  private = list(
    pending_requests = NULL,
    notification_handler = NULL,
    request_handlers = NULL,
    running = FALSE,
    write_lock = FALSE,
    next_id = 1L,
    read_buffer = raw(0),

    new_id = function() {
      id <- private$next_id
      private$next_id <- private$next_id + 1L
      id
    },

    send_message = function(message) {
      content <- jsonlite::toJSON(message, auto_unbox = TRUE, null = "null")
      content_bytes <- charToRaw(as.character(content))
      header <- paste0("Content-Length: ", length(content_bytes), "\r\n\r\n")
      header_bytes <- charToRaw(header)

      # Write header then content to stdin
      self$process$write_input(header_bytes)
      self$process$write_input(content_bytes)
    },

    read_message = function(timeout_ms = 1000L) {
      # Try to read a complete message from the process stdout.
      # Uses Content-Length header framing.

      # First, try to poll for available data
      poll_result <- self$process$poll_io(timeout_ms)

      # Read any available stdout data into our buffer
      if (!is.null(poll_result) && "output" %in% names(poll_result) &&
          poll_result[["output"]] == "ready") {
        new_data <- self$process$read_output_raw()
        if (length(new_data) > 0) {
          private$read_buffer <- c(private$read_buffer, new_data)
        }
      }

      # Try to parse a complete message from the buffer
      private$try_parse_message()
    },

    try_parse_message = function() {
      buf <- private$read_buffer
      if (length(buf) == 0) return(NULL)

      buf_str <- rawToChar(buf)

      # Look for Content-Length header
      header_end <- regexpr("\r\n\r\n", buf_str, fixed = TRUE)
      if (header_end == -1L) return(NULL)

      header_str <- substr(buf_str, 1, header_end - 1L)

      # Parse Content-Length
      cl_match <- regmatches(header_str, regexpr("Content-Length:\\s*(\\d+)", header_str, perl = TRUE))
      if (length(cl_match) == 0) return(NULL)

      content_length <- as.integer(sub("Content-Length:\\s*", "", cl_match))

      # Check if we have enough data for the full message
      header_total_bytes <- length(charToRaw(substr(buf_str, 1, header_end + 3L)))
      total_needed <- header_total_bytes + content_length

      if (length(buf) < total_needed) return(NULL)

      # Extract the content bytes
      content_raw <- buf[(header_total_bytes + 1):(header_total_bytes + content_length)]
      content_str <- rawToChar(content_raw)

      # Remove consumed bytes from buffer
      if (total_needed < length(buf)) {
        private$read_buffer <- buf[(total_needed + 1):length(buf)]
      } else {
        private$read_buffer <- raw(0)
      }

      # Parse JSON
      tryCatch(
        jsonlite::fromJSON(content_str, simplifyVector = FALSE),
        error = function(e) {
          warning(paste("Failed to parse JSON-RPC message:", e$message))
          NULL
        }
      )
    },

    handle_incoming = function(msg) {
      # Server notification (no id)
      if (is.null(msg$id) && !is.null(msg$method)) {
        if (!is.null(private$notification_handler)) {
          params <- msg$params %||% list()
          tryCatch(
            private$notification_handler(msg$method, params),
            error = function(e) {
              warning(paste("Error in notification handler:", e$message))
            }
          )
        }
        return(invisible(NULL))
      }

      # Server request (has both id and method)
      if (!is.null(msg$id) && !is.null(msg$method)) {
        handler <- private$request_handlers[[msg$method]]
        if (is.null(handler)) {
          private$send_error_response(msg$id, -32601L,
                                       paste0("Method not found: ", msg$method), NULL)
          return(invisible(NULL))
        }

        params <- msg$params %||% list()
        tryCatch(
          {
            outcome <- handler(params)
            if (is.null(outcome)) outcome <- list()
            private$send_response(msg$id, outcome)
          },
          json_rpc_error = function(e) {
            private$send_error_response(msg$id, e$code, e$rpc_message, e$data)
          },
          error = function(e) {
            private$send_error_response(msg$id, -32603L, e$message, NULL)
          }
        )
        return(invisible(NULL))
      }

      # Otherwise it might be a response to a pending request handled
      # in the request() blocking loop -- this case should not normally
      # reach here, but we'll ignore it gracefully.
      invisible(NULL)
    },

    send_response = function(request_id, result) {
      response <- list(
        jsonrpc = "2.0",
        id = request_id,
        result = result
      )
      private$send_message(response)
    },

    send_error_response = function(request_id, code, message, data) {
      response <- list(
        jsonrpc = "2.0",
        id = request_id,
        error = list(
          code = code,
          message = message,
          data = data
        )
      )
      private$send_message(response)
    }
  )
)
