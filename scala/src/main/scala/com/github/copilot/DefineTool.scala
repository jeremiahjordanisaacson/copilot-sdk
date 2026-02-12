// Copyright (c) Microsoft Corporation. All rights reserved.

package com.github.copilot

import io.circe.*
import io.circe.syntax.*
import scala.concurrent.{ExecutionContext, Future}

/**
 * Helper object for defining tools with a builder-style API.
 *
 * == Usage ==
 * {{{
 * val weatherTool = DefineTool(
 *   name = "get_weather",
 *   description = "Get current weather for a location",
 *   parameters = JsonObject(
 *     "type" -> "object".asJson,
 *     "properties" -> Json.obj(
 *       "location" -> Json.obj(
 *         "type" -> "string".asJson,
 *         "description" -> "City name".asJson
 *       )
 *     ),
 *     "required" -> Json.arr("location".asJson)
 *   )
 * ) { (args, invocation) =>
 *   val location = args.hcursor.get[String]("location").getOrElse("unknown")
 *   Future.successful(ToolResultObject(
 *     textResultForLlm = s"Weather in $location: 72F, sunny",
 *     resultType = ToolResultType.Success
 *   ))
 * }
 * }}}
 */
object DefineTool:

  /**
   * Define a tool with a handler that returns a Future[ToolResultObject].
   *
   * @param name         Unique tool name
   * @param description  Human-readable description
   * @param parameters   JSON Schema describing the tool's parameters
   * @param handler      Function invoked when the CLI calls this tool
   * @return A [[Tool]] instance ready for use in a [[SessionConfig]]
   */
  def apply(
    name: String,
    description: String = "",
    parameters: JsonObject = JsonObject.empty
  )(handler: (Json, ToolInvocation) => Future[ToolResultObject]): Tool =
    Tool(
      name = name,
      description = if description.nonEmpty then Some(description) else None,
      parameters = if parameters.isEmpty then None else Some(parameters),
      handler = handler
    )

  /**
   * Define a tool with a synchronous handler that returns a ToolResultObject.
   *
   * @param name         Unique tool name
   * @param description  Human-readable description
   * @param parameters   JSON Schema describing the tool's parameters
   * @param handler      Synchronous function invoked when the CLI calls this tool
   * @return A [[Tool]] instance
   */
  def sync(
    name: String,
    description: String = "",
    parameters: JsonObject = JsonObject.empty
  )(handler: (Json, ToolInvocation) => ToolResultObject)(using ec: ExecutionContext): Tool =
    Tool(
      name = name,
      description = if description.nonEmpty then Some(description) else None,
      parameters = if parameters.isEmpty then None else Some(parameters),
      handler = (args, inv) => Future(handler(args, inv))
    )

  /**
   * Define a tool with a simple string result handler.
   *
   * The returned string is automatically wrapped in a successful ToolResultObject.
   *
   * @param name         Unique tool name
   * @param description  Human-readable description
   * @param parameters   JSON Schema describing the tool's parameters
   * @param handler      Function that returns a string result
   * @return A [[Tool]] instance
   */
  def simple(
    name: String,
    description: String = "",
    parameters: JsonObject = JsonObject.empty
  )(handler: (Json, ToolInvocation) => Future[String])(using ec: ExecutionContext): Tool =
    Tool(
      name = name,
      description = if description.nonEmpty then Some(description) else None,
      parameters = if parameters.isEmpty then None else Some(parameters),
      handler = (args, inv) =>
        handler(args, inv).map { text =>
          ToolResultObject(
            textResultForLlm = text,
            resultType = ToolResultType.Success,
            toolTelemetry = Some(Map.empty)
          )
        }
    )

  /**
   * Define a tool with a synchronous string result handler.
   *
   * @param name         Unique tool name
   * @param description  Human-readable description
   * @param parameters   JSON Schema describing the tool's parameters
   * @param handler      Synchronous function that returns a string result
   * @return A [[Tool]] instance
   */
  def simpleSync(
    name: String,
    description: String = "",
    parameters: JsonObject = JsonObject.empty
  )(handler: (Json, ToolInvocation) => String)(using ec: ExecutionContext): Tool =
    Tool(
      name = name,
      description = if description.nonEmpty then Some(description) else None,
      parameters = if parameters.isEmpty then None else Some(parameters),
      handler = (args, inv) =>
        Future:
          val text = handler(args, inv)
          ToolResultObject(
            textResultForLlm = text,
            resultType = ToolResultType.Success,
            toolTelemetry = Some(Map.empty)
          )
    )
