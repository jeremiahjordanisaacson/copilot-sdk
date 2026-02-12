#' Type definitions for the Copilot R SDK
#'
#' R6 classes representing the data types used in the Copilot SDK protocol.
#' These mirror the types in the Python/Node.js/Go/.NET SDKs.

# ---------------------------------------------------------------------------
# SessionEvent
# ---------------------------------------------------------------------------

#' SessionEvent
#'
#' Represents an event emitted by a Copilot session.
#'
#' @field type Character. The event type (e.g. "assistant.message", "session.idle").
#' @field id Character. UUID of the event.
#' @field timestamp Character. ISO 8601 timestamp.
#' @field data List. Event-specific data payload.
#' @field ephemeral Logical or NULL. Whether this event is ephemeral.
#' @field parent_id Character or NULL. Parent event UUID.
#' @export
SessionEvent <- R6::R6Class(
  "SessionEvent",
  public = list(
    type = NULL,
    id = NULL,
    timestamp = NULL,
    data = NULL,
    ephemeral = NULL,
    parent_id = NULL,

    #' @description Create a new SessionEvent.
    #' @param type Event type string.
    #' @param id Event UUID string.
    #' @param timestamp ISO 8601 timestamp string.
    #' @param data Event data as a named list.
    #' @param ephemeral Logical or NULL.
    #' @param parent_id Parent event UUID string or NULL.
    initialize = function(type, id, timestamp, data, ephemeral = NULL, parent_id = NULL) {
      self$type <- type
      self$id <- id
      self$timestamp <- timestamp
      self$data <- data
      self$ephemeral <- ephemeral
      self$parent_id <- parent_id
    },

    #' @description Convert to list for JSON serialization.
    to_list = function() {
      result <- list(
        type = self$type,
        id = self$id,
        timestamp = self$timestamp,
        data = self$data
      )
      if (!is.null(self$ephemeral)) result$ephemeral <- self$ephemeral
      if (!is.null(self$parent_id)) result$parentId <- self$parent_id
      result
    }
  )
)

#' Create a SessionEvent from a named list (parsed JSON).
#'
#' @param obj A named list from parsed JSON.
#' @return A SessionEvent R6 object.
#' @keywords internal
session_event_from_list <- function(obj) {
  SessionEvent$new(
    type = obj$type %||% "unknown",
    id = obj$id %||% "",
    timestamp = obj$timestamp %||% "",
    data = obj$data %||% list(),
    ephemeral = obj$ephemeral,
    parent_id = obj$parentId
  )
}


# ---------------------------------------------------------------------------
# PermissionRequest / PermissionRequestResult
# ---------------------------------------------------------------------------

#' PermissionRequest
#'
#' Represents a permission request from the server.
#'
#' @field kind Character. The kind of permission ("shell", "write", "mcp", "read", "url").
#' @field tool_call_id Character. The tool call ID.
#' @field extra List. Additional fields depending on kind.
#' @export
PermissionRequest <- R6::R6Class(
  "PermissionRequest",
  public = list(
    kind = NULL,
    tool_call_id = NULL,
    extra = NULL,

    #' @description Create a new PermissionRequest.
    #' @param kind Permission kind string.
    #' @param tool_call_id Tool call ID string.
    #' @param extra Named list of additional fields.
    initialize = function(kind = NULL, tool_call_id = NULL, extra = list()) {
      self$kind <- kind
      self$tool_call_id <- tool_call_id
      self$extra <- extra
    },

    #' @description Convert to list.
    to_list = function() {
      result <- self$extra
      if (!is.null(self$kind)) result$kind <- self$kind
      if (!is.null(self$tool_call_id)) result$toolCallId <- self$tool_call_id
      result
    }
  )
)

#' PermissionRequestResult
#'
#' Result of a permission request.
#'
#' @field kind Character. Decision kind.
#' @field rules List or NULL. Associated rules.
#' @export
PermissionRequestResult <- R6::R6Class(
  "PermissionRequestResult",
  public = list(
    kind = NULL,
    rules = NULL,

    #' @description Create a new PermissionRequestResult.
    #' @param kind Decision kind string.
    #' @param rules List or NULL.
    initialize = function(kind, rules = NULL) {
      self$kind <- kind
      self$rules <- rules
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list(kind = self$kind)
      if (!is.null(self$rules)) result$rules <- self$rules
      result
    }
  )
)


# ---------------------------------------------------------------------------
# UserInputRequest / UserInputResponse
# ---------------------------------------------------------------------------

#' UserInputRequest
#'
#' Request for user input from the agent (enables ask_user tool).
#'
#' @field question Character. The question to ask.
#' @field choices Character vector or NULL. Optional list of choices.
#' @field allow_freeform Logical. Whether freeform input is allowed.
#' @export
UserInputRequest <- R6::R6Class(
  "UserInputRequest",
  public = list(
    question = NULL,
    choices = NULL,
    allow_freeform = TRUE,

    #' @description Create a new UserInputRequest.
    #' @param question The question string.
    #' @param choices Character vector or NULL.
    #' @param allow_freeform Logical, default TRUE.
    initialize = function(question = "", choices = NULL, allow_freeform = TRUE) {
      self$question <- question
      self$choices <- choices
      self$allow_freeform <- allow_freeform
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list(question = self$question, allowFreeform = self$allow_freeform)
      if (!is.null(self$choices)) result$choices <- self$choices
      result
    }
  )
)

#' UserInputResponse
#'
#' Response to a user input request.
#'
#' @field answer Character. The answer text.
#' @field was_freeform Logical. Whether the answer was freeform.
#' @export
UserInputResponse <- R6::R6Class(
  "UserInputResponse",
  public = list(
    answer = NULL,
    was_freeform = FALSE,

    #' @description Create a new UserInputResponse.
    #' @param answer Answer string.
    #' @param was_freeform Logical.
    initialize = function(answer, was_freeform = FALSE) {
      self$answer <- answer
      self$was_freeform <- was_freeform
    },

    #' @description Convert to list.
    to_list = function() {
      list(answer = self$answer, wasFreeform = self$was_freeform)
    }
  )
)


# ---------------------------------------------------------------------------
# PingResponse
# ---------------------------------------------------------------------------

#' PingResponse
#'
#' Response from a ping request.
#'
#' @field message Character. Echo message with "pong: " prefix.
#' @field timestamp Numeric. Server timestamp in milliseconds.
#' @field protocol_version Integer. Protocol version for SDK compatibility.
#' @export
PingResponse <- R6::R6Class(
  "PingResponse",
  public = list(
    message = NULL,
    timestamp = NULL,
    protocol_version = NULL,

    #' @description Create a new PingResponse.
    #' @param message Character.
    #' @param timestamp Numeric.
    #' @param protocol_version Integer.
    initialize = function(message, timestamp, protocol_version) {
      self$message <- message
      self$timestamp <- timestamp
      self$protocol_version <- as.integer(protocol_version)
    },

    #' @description Convert to list.
    to_list = function() {
      list(
        message = self$message,
        timestamp = self$timestamp,
        protocolVersion = self$protocol_version
      )
    }
  )
)

#' Create a PingResponse from a named list.
#' @param obj Named list from parsed JSON.
#' @return PingResponse R6 object.
#' @keywords internal
ping_response_from_list <- function(obj) {
  PingResponse$new(
    message = obj$message,
    timestamp = obj$timestamp,
    protocol_version = obj$protocolVersion
  )
}


# ---------------------------------------------------------------------------
# Model types
# ---------------------------------------------------------------------------

#' ModelSupports
#'
#' Model support flags.
#'
#' @field vision Logical. Whether vision is supported.
#' @field reasoning_effort Logical. Whether reasoning effort is supported.
#' @export
ModelSupports <- R6::R6Class(
  "ModelSupports",
  public = list(
    vision = FALSE,
    reasoning_effort = FALSE,

    #' @description Create a new ModelSupports.
    #' @param vision Logical.
    #' @param reasoning_effort Logical.
    initialize = function(vision = FALSE, reasoning_effort = FALSE) {
      self$vision <- vision
      self$reasoning_effort <- reasoning_effort
    },

    #' @description Convert to list.
    to_list = function() {
      list(vision = self$vision, reasoningEffort = self$reasoning_effort)
    }
  )
)

#' ModelLimits
#'
#' Model limits.
#'
#' @field max_prompt_tokens Numeric or NULL.
#' @field max_context_window_tokens Numeric or NULL.
#' @export
ModelLimits <- R6::R6Class(
  "ModelLimits",
  public = list(
    max_prompt_tokens = NULL,
    max_context_window_tokens = NULL,

    #' @description Create a new ModelLimits.
    #' @param max_prompt_tokens Numeric or NULL.
    #' @param max_context_window_tokens Numeric or NULL.
    initialize = function(max_prompt_tokens = NULL, max_context_window_tokens = NULL) {
      self$max_prompt_tokens <- max_prompt_tokens
      self$max_context_window_tokens <- max_context_window_tokens
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list()
      if (!is.null(self$max_prompt_tokens)) result$max_prompt_tokens <- self$max_prompt_tokens
      if (!is.null(self$max_context_window_tokens)) {
        result$max_context_window_tokens <- self$max_context_window_tokens
      }
      result
    }
  )
)

#' ModelCapabilities
#'
#' Model capabilities and limits.
#'
#' @field supports ModelSupports R6 object.
#' @field limits ModelLimits R6 object.
#' @export
ModelCapabilities <- R6::R6Class(
  "ModelCapabilities",
  public = list(
    supports = NULL,
    limits = NULL,

    #' @description Create a new ModelCapabilities.
    #' @param supports ModelSupports R6 object.
    #' @param limits ModelLimits R6 object.
    initialize = function(supports, limits) {
      self$supports <- supports
      self$limits <- limits
    },

    #' @description Convert to list.
    to_list = function() {
      list(supports = self$supports$to_list(), limits = self$limits$to_list())
    }
  )
)

#' ModelPolicy
#'
#' Model policy state.
#'
#' @field state Character. "enabled", "disabled", or "unconfigured".
#' @field terms Character. Policy terms.
#' @export
ModelPolicy <- R6::R6Class(
  "ModelPolicy",
  public = list(
    state = NULL,
    terms = NULL,

    #' @description Create a new ModelPolicy.
    #' @param state Character.
    #' @param terms Character.
    initialize = function(state, terms) {
      self$state <- state
      self$terms <- terms
    },

    #' @description Convert to list.
    to_list = function() {
      list(state = self$state, terms = self$terms)
    }
  )
)

#' ModelBilling
#'
#' Model billing information.
#'
#' @field multiplier Numeric. Billing multiplier.
#' @export
ModelBilling <- R6::R6Class(
  "ModelBilling",
  public = list(
    multiplier = NULL,

    #' @description Create a new ModelBilling.
    #' @param multiplier Numeric.
    initialize = function(multiplier) {
      self$multiplier <- multiplier
    },

    #' @description Convert to list.
    to_list = function() {
      list(multiplier = self$multiplier)
    }
  )
)

#' ModelInfo
#'
#' Information about an available model.
#'
#' @field id Character. Model identifier (e.g., "claude-sonnet-4.5").
#' @field name Character. Display name.
#' @field capabilities ModelCapabilities R6 object.
#' @field policy ModelPolicy or NULL.
#' @field billing ModelBilling or NULL.
#' @field supported_reasoning_efforts Character vector or NULL.
#' @field default_reasoning_effort Character or NULL.
#' @export
ModelInfo <- R6::R6Class(
  "ModelInfo",
  public = list(
    id = NULL,
    name = NULL,
    capabilities = NULL,
    policy = NULL,
    billing = NULL,
    supported_reasoning_efforts = NULL,
    default_reasoning_effort = NULL,

    #' @description Create a new ModelInfo.
    #' @param id Character.
    #' @param name Character.
    #' @param capabilities ModelCapabilities R6 object.
    #' @param policy ModelPolicy or NULL.
    #' @param billing ModelBilling or NULL.
    #' @param supported_reasoning_efforts Character vector or NULL.
    #' @param default_reasoning_effort Character or NULL.
    initialize = function(id, name, capabilities, policy = NULL, billing = NULL,
                          supported_reasoning_efforts = NULL,
                          default_reasoning_effort = NULL) {
      self$id <- id
      self$name <- name
      self$capabilities <- capabilities
      self$policy <- policy
      self$billing <- billing
      self$supported_reasoning_efforts <- supported_reasoning_efforts
      self$default_reasoning_effort <- default_reasoning_effort
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list(
        id = self$id,
        name = self$name,
        capabilities = self$capabilities$to_list()
      )
      if (!is.null(self$policy)) result$policy <- self$policy$to_list()
      if (!is.null(self$billing)) result$billing <- self$billing$to_list()
      if (!is.null(self$supported_reasoning_efforts)) {
        result$supportedReasoningEfforts <- self$supported_reasoning_efforts
      }
      if (!is.null(self$default_reasoning_effort)) {
        result$defaultReasoningEffort <- self$default_reasoning_effort
      }
      result
    }
  )
)

#' Create a ModelInfo from a named list (parsed JSON).
#' @param obj Named list from parsed JSON.
#' @return ModelInfo R6 object.
#' @keywords internal
model_info_from_list <- function(obj) {
  caps_obj <- obj$capabilities
  supports_obj <- caps_obj$supports %||% list()
  limits_obj <- caps_obj$limits %||% list()

  supports <- ModelSupports$new(
    vision = isTRUE(supports_obj$vision),
    reasoning_effort = isTRUE(supports_obj$reasoningEffort)
  )
  limits <- ModelLimits$new(
    max_prompt_tokens = limits_obj$max_prompt_tokens,
    max_context_window_tokens = limits_obj$max_context_window_tokens
  )
  capabilities <- ModelCapabilities$new(supports = supports, limits = limits)

  policy <- NULL
  if (!is.null(obj$policy)) {
    policy <- ModelPolicy$new(state = obj$policy$state, terms = obj$policy$terms)
  }

  billing <- NULL
  if (!is.null(obj$billing)) {
    billing <- ModelBilling$new(multiplier = obj$billing$multiplier)
  }

  ModelInfo$new(
    id = obj$id,
    name = obj$name,
    capabilities = capabilities,
    policy = policy,
    billing = billing,
    supported_reasoning_efforts = obj$supportedReasoningEfforts,
    default_reasoning_effort = obj$defaultReasoningEffort
  )
}


# ---------------------------------------------------------------------------
# SessionMetadata
# ---------------------------------------------------------------------------

#' SessionMetadata
#'
#' Metadata about a session.
#'
#' @field session_id Character. Session identifier.
#' @field start_time Character. ISO 8601 timestamp when session was created.
#' @field modified_time Character. ISO 8601 timestamp when session was last modified.
#' @field is_remote Logical. Whether the session is remote.
#' @field summary Character or NULL. Optional summary.
#' @export
SessionMetadata <- R6::R6Class(
  "SessionMetadata",
  public = list(
    session_id = NULL,
    start_time = NULL,
    modified_time = NULL,
    is_remote = FALSE,
    summary = NULL,

    #' @description Create a new SessionMetadata.
    #' @param session_id Character.
    #' @param start_time Character.
    #' @param modified_time Character.
    #' @param is_remote Logical.
    #' @param summary Character or NULL.
    initialize = function(session_id, start_time, modified_time, is_remote, summary = NULL) {
      self$session_id <- session_id
      self$start_time <- start_time
      self$modified_time <- modified_time
      self$is_remote <- is_remote
      self$summary <- summary
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list(
        sessionId = self$session_id,
        startTime = self$start_time,
        modifiedTime = self$modified_time,
        isRemote = self$is_remote
      )
      if (!is.null(self$summary)) result$summary <- self$summary
      result
    }
  )
)

#' Create a SessionMetadata from a named list.
#' @param obj Named list.
#' @return SessionMetadata R6 object.
#' @keywords internal
session_metadata_from_list <- function(obj) {
  SessionMetadata$new(
    session_id = obj$sessionId,
    start_time = obj$startTime,
    modified_time = obj$modifiedTime,
    is_remote = isTRUE(obj$isRemote),
    summary = obj$summary
  )
}


# ---------------------------------------------------------------------------
# SessionLifecycleEvent
# ---------------------------------------------------------------------------

#' SessionLifecycleEvent
#'
#' Session lifecycle event notification.
#'
#' @field type Character. Event type (e.g. "session.created", "session.deleted").
#' @field session_id Character. Session identifier.
#' @field metadata Named list or NULL. Lifecycle event metadata.
#' @export
SessionLifecycleEvent <- R6::R6Class(
  "SessionLifecycleEvent",
  public = list(
    type = NULL,
    session_id = NULL,
    metadata = NULL,

    #' @description Create a new SessionLifecycleEvent.
    #' @param type Event type string.
    #' @param session_id Session ID string.
    #' @param metadata Named list or NULL.
    initialize = function(type, session_id, metadata = NULL) {
      self$type <- type
      self$session_id <- session_id
      self$metadata <- metadata
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list(type = self$type, sessionId = self$session_id)
      if (!is.null(self$metadata)) result$metadata <- self$metadata
      result
    }
  )
)

#' Create a SessionLifecycleEvent from a named list.
#' @param obj Named list.
#' @return SessionLifecycleEvent R6 object.
#' @keywords internal
session_lifecycle_event_from_list <- function(obj) {
  SessionLifecycleEvent$new(
    type = obj$type %||% "session.updated",
    session_id = obj$sessionId %||% "",
    metadata = obj$metadata
  )
}


# ---------------------------------------------------------------------------
# ToolResultObject / ToolInvocation / Tool
# ---------------------------------------------------------------------------

#' ToolResultObject
#'
#' Result of a tool invocation.
#'
#' @field text_result_for_llm Character. Text result for the LLM.
#' @field result_type Character. "success", "failure", "rejected", or "denied".
#' @field error Character or NULL. Error message if any.
#' @field session_log Character or NULL. Session log message.
#' @field tool_telemetry Named list or NULL. Telemetry data.
#' @export
ToolResultObject <- R6::R6Class(
  "ToolResultObject",
  public = list(
    text_result_for_llm = "",
    result_type = "success",
    error = NULL,
    session_log = NULL,
    tool_telemetry = NULL,

    #' @description Create a new ToolResultObject.
    #' @param text_result_for_llm Character.
    #' @param result_type Character.
    #' @param error Character or NULL.
    #' @param session_log Character or NULL.
    #' @param tool_telemetry Named list or NULL.
    initialize = function(text_result_for_llm = "", result_type = "success",
                          error = NULL, session_log = NULL, tool_telemetry = NULL) {
      self$text_result_for_llm <- text_result_for_llm
      self$result_type <- result_type
      self$error <- error
      self$session_log <- session_log
      self$tool_telemetry <- tool_telemetry
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list(
        textResultForLlm = self$text_result_for_llm,
        resultType = self$result_type
      )
      if (!is.null(self$error)) result$error <- self$error
      if (!is.null(self$session_log)) result$sessionLog <- self$session_log
      if (!is.null(self$tool_telemetry)) result$toolTelemetry <- self$tool_telemetry
      result
    }
  )
)

#' ToolInvocation
#'
#' Represents a tool invocation context.
#'
#' @field session_id Character. The session making the tool call.
#' @field tool_call_id Character. Unique ID for this tool call.
#' @field tool_name Character. Name of the tool being called.
#' @field arguments Any. The arguments passed to the tool.
#' @export
ToolInvocation <- R6::R6Class(
  "ToolInvocation",
  public = list(
    session_id = NULL,
    tool_call_id = NULL,
    tool_name = NULL,
    arguments = NULL,

    #' @description Create a new ToolInvocation.
    #' @param session_id Character.
    #' @param tool_call_id Character.
    #' @param tool_name Character.
    #' @param arguments Any.
    initialize = function(session_id, tool_call_id, tool_name, arguments = NULL) {
      self$session_id <- session_id
      self$tool_call_id <- tool_call_id
      self$tool_name <- tool_name
      self$arguments <- arguments
    }
  )
)

#' Tool
#'
#' Definition of a custom tool exposed to the Copilot CLI.
#'
#' @field name Character. Tool name.
#' @field description Character. Tool description shown to the LLM.
#' @field handler Function. The handler function(invocation) -> ToolResultObject or list.
#' @field parameters Named list or NULL. JSON schema for parameters.
#' @export
Tool <- R6::R6Class(
  "Tool",
  public = list(
    name = NULL,
    description = NULL,
    handler = NULL,
    parameters = NULL,

    #' @description Create a new Tool.
    #' @param name Character. Tool name.
    #' @param description Character. Tool description.
    #' @param handler Function accepting a ToolInvocation, returning a ToolResultObject or list.
    #' @param parameters Named list or NULL. JSON schema for parameters.
    initialize = function(name, description, handler, parameters = NULL) {
      self$name <- name
      self$description <- description
      self$handler <- handler
      self$parameters <- parameters
    }
  )
)


# ---------------------------------------------------------------------------
# MessageOptions
# ---------------------------------------------------------------------------

#' MessageOptions
#'
#' Options for sending a message to a session.
#'
#' @field prompt Character. The prompt/message text to send.
#' @field attachments List or NULL. Optional file/directory attachments.
#' @field mode Character or NULL. Message processing mode ("enqueue" or "immediate").
#' @field response_format Character or NULL. Response format ("text", "image", or "json_object").
#' @field image_options List or NULL. Image generation options (from \code{image_options()}).
#' @export
MessageOptions <- R6::R6Class(
  "MessageOptions",
  public = list(
    prompt = NULL,
    attachments = NULL,
    mode = NULL,
    response_format = NULL,
    image_options = NULL,

    #' @description Create new MessageOptions.
    #' @param prompt Character. The prompt text.
    #' @param attachments List or NULL.
    #' @param mode Character or NULL.
    #' @param response_format Character or NULL. One of RESPONSE_FORMATS.
    #' @param image_options List or NULL. Image generation options.
    initialize = function(prompt, attachments = NULL, mode = NULL,
                          response_format = NULL, image_options = NULL) {
      self$prompt <- prompt
      self$attachments <- attachments
      self$mode <- mode
      self$response_format <- response_format
      self$image_options <- image_options
    },

    #' @description Convert to list.
    to_list = function() {
      result <- list(prompt = self$prompt)
      if (!is.null(self$attachments)) result$attachments <- self$attachments
      if (!is.null(self$mode)) result$mode <- self$mode
      if (!is.null(self$response_format)) result$responseFormat <- self$response_format
      if (!is.null(self$image_options)) result$imageOptions <- self$image_options
      result
    }
  )
)


# ---------------------------------------------------------------------------
# Image Generation Types
# ---------------------------------------------------------------------------

#' Valid response format values
#' @export
RESPONSE_FORMATS <- c("text", "image", "json_object")

#' Create image options for image generation
#'
#' @param size Image size (e.g. "1024x1024")
#' @param quality Image quality ("hd" or "standard")
#' @param style Image style ("natural" or "vivid")
#' @return A list of image options
#' @export
image_options <- function(size = NULL, quality = NULL, style = NULL) {
  opts <- list()
  if (!is.null(size)) opts$size <- size
  if (!is.null(quality)) opts$quality <- quality
  if (!is.null(style)) opts$style <- style
  opts
}

#' Parse assistant image data from JSON response
#'
#' @param data A list containing image data fields
#' @return A list with format, base64, url, revisedPrompt, width, height
#' @export
parse_assistant_image_data <- function(data) {
  list(
    format = data$format,
    base64 = data$base64,
    url = data$url,
    revisedPrompt = data$revisedPrompt,
    width = data$width,
    height = data$height
  )
}

#' Parse a content block from a mixed text+image response
#'
#' @param block A list with type and content fields
#' @return A parsed content block list
#' @export
parse_content_block <- function(block) {
  if (block$type == "image" && !is.null(block$image)) {
    block$image <- parse_assistant_image_data(block$image)
  }
  block
}


# ---------------------------------------------------------------------------
# NULL-coalescing operator
# ---------------------------------------------------------------------------

#' @keywords internal
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}
