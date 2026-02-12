#' Define a tool for the Copilot SDK
#'
#' Helper function to create a Tool R6 object with a handler function.
#' Provides a convenient way to define tools with automatic result normalization.
#'
#' The handler function receives a \code{ToolInvocation} R6 object and should return
#' one of:
#' \itemize{
#'   \item A character string (converted to a success ToolResultObject)
#'   \item A \code{ToolResultObject} R6 object
#'   \item A named list with \code{textResultForLlm} and \code{resultType} fields
#'   \item Any other value (JSON-serialized as a success result)
#'   \item NULL (converted to failure with "Tool returned no result")
#' }
#'
#' @param name Character. The tool name.
#' @param description Character. Description of what the tool does (shown to the LLM).
#' @param handler Function. A function(invocation) where invocation is a ToolInvocation.
#' @param parameters Named list or NULL. JSON schema for tool parameters.
#'   Example: \code{list(type = "object", properties = list(query = list(type = "string")),
#'   required = list("query"))}
#'
#' @return A Tool R6 object.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Simple tool returning a string
#' my_tool <- define_tool(
#'   name = "lookup_fact",
#'   description = "Returns a fun fact about a topic",
#'   parameters = list(
#'     type = "object",
#'     properties = list(
#'       topic = list(type = "string", description = "Topic to look up")
#'     ),
#'     required = list("topic")
#'   ),
#'   handler = function(invocation) {
#'     topic <- invocation$arguments$topic
#'     facts <- list(
#'       r = "R was created in 1993 by Ross Ihaka and Robert Gentleman.",
#'       python = "Python was created in 1991 by Guido van Rossum."
#'     )
#'     facts[[tolower(topic)]] %||% paste0("No fact stored for ", topic, ".")
#'   }
#' )
#'
#' # Tool returning a ToolResultObject
#' my_tool2 <- define_tool(
#'   name = "search",
#'   description = "Search the database",
#'   handler = function(invocation) {
#'     query <- invocation$arguments$query
#'     ToolResultObject$new(
#'       text_result_for_llm = paste0("Found results for: ", query),
#'       result_type = "success",
#'       session_log = paste0("Searched for: ", query)
#'     )
#'   }
#' )
#' }
define_tool <- function(name, description, handler, parameters = NULL) {
  # Wrap the handler to normalize results
  wrapped_handler <- function(invocation) {
    result <- tryCatch(
      handler(invocation),
      error = function(e) {
        ToolResultObject$new(
          text_result_for_llm = "Invoking this tool produced an error. Detailed information is not available.",
          result_type = "failure",
          error = e$message,
          tool_telemetry = list()
        )
      }
    )

    # Normalize the result
    if (is.null(result)) {
      return(ToolResultObject$new(
        text_result_for_llm = "Tool returned no result.",
        result_type = "failure",
        error = "tool returned no result",
        tool_telemetry = list()
      ))
    }

    if (inherits(result, "ToolResultObject")) {
      return(result)
    }

    if (is.list(result) && !is.null(result$textResultForLlm)) {
      return(result)
    }

    if (is.character(result) && length(result) == 1) {
      return(ToolResultObject$new(
        text_result_for_llm = result,
        result_type = "success"
      ))
    }

    # JSON-serialize anything else
    ToolResultObject$new(
      text_result_for_llm = as.character(jsonlite::toJSON(result, auto_unbox = TRUE)),
      result_type = "success"
    )
  }

  Tool$new(
    name = name,
    description = description,
    handler = wrapped_handler,
    parameters = parameters
  )
}
