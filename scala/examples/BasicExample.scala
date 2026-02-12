// Copyright (c) Microsoft Corporation. All rights reserved.

// Basic example demonstrating the Copilot Scala SDK.
// Run with: sbt "runMain BasicExample"

import com.github.copilot.*
import io.circe.*
import io.circe.syntax.*

import scala.concurrent.{Await, ExecutionContext, Future}
import scala.concurrent.duration.*

@main def BasicExample(): Unit =
  given ExecutionContext = ExecutionContext.global

  // -------------------------------------------------------------------------
  // 1. Create the client
  // -------------------------------------------------------------------------
  // Default options spawn the bundled CLI process using stdio transport.
  // Set cliPath if the CLI is at a custom location.
  val client = CopilotClient(CopilotClientOptions(
    cliPath = Some("copilot"),  // adjust to your CLI path
    logLevel = "info"
  ))

  try
    // Start the client (spawns CLI process, connects via stdio, verifies protocol)
    println("Starting Copilot client...")
    Await.result(client.start(), 30.seconds)
    println(s"Client connected (state: ${client.getState})")

    // -----------------------------------------------------------------------
    // 2. Ping the server
    // -----------------------------------------------------------------------
    val pingResponse = Await.result(client.ping(Some("hello from Scala")), 10.seconds)
    println(s"Ping response: message=${pingResponse.message}, " +
      s"protocolVersion=${pingResponse.protocolVersion.getOrElse("unknown")}")

    // -----------------------------------------------------------------------
    // 3. List available models
    // -----------------------------------------------------------------------
    val models = Await.result(client.listModels(), 15.seconds)
    println(s"Available models (${models.size}):")
    models.take(5).foreach { m =>
      println(s"  - ${m.id} (${m.name})")
    }

    // -----------------------------------------------------------------------
    // 4. Define a custom tool
    // -----------------------------------------------------------------------
    val weatherTool = DefineTool(
      name = "get_weather",
      description = "Get the current weather for a location",
      parameters = JsonObject(
        "type" -> "object".asJson,
        "properties" -> Json.obj(
          "location" -> Json.obj(
            "type" -> "string".asJson,
            "description" -> "The city and state, e.g. San Francisco, CA".asJson
          )
        ),
        "required" -> Json.arr("location".asJson)
      )
    ) { (args, invocation) =>
      val location = args.hcursor.get[String]("location").getOrElse("unknown")
      println(s"  [Tool] get_weather called for: $location")
      Future.successful(ToolResultObject(
        textResultForLlm = s"The weather in $location is 72F and sunny.",
        resultType = ToolResultType.Success,
        toolTelemetry = Some(Map.empty)
      ))
    }

    // -----------------------------------------------------------------------
    // 5. Create a session with the tool
    // -----------------------------------------------------------------------
    println("\nCreating session...")
    val session = Await.result(
      client.createSession(SessionConfig(
        tools = List(weatherTool),
        onPermissionRequest = Some { (request, invocation) =>
          println(s"  [Permission] ${request.kind} requested")
          Future.successful(PermissionRequestResult(kind = PermissionRequestResult.Approved))
        }
      )),
      30.seconds
    )
    println(s"Session created: ${session.sessionId}")

    // -----------------------------------------------------------------------
    // 6. Subscribe to events
    // -----------------------------------------------------------------------
    session.on { event =>
      event.`type` match
        case SessionEventType.AssistantMessage =>
          val content = event.data.hcursor.get[String]("content").getOrElse("")
          println(s"\n  [Assistant] $content")
        case SessionEventType.ToolExecutionStart =>
          val toolName = event.data.hcursor.get[String]("toolName").getOrElse("")
          println(s"  [Tool Start] $toolName")
        case SessionEventType.ToolExecutionComplete =>
          val toolName = event.data.hcursor.get[String]("toolName").getOrElse("")
          println(s"  [Tool Complete] $toolName")
        case SessionEventType.SessionIdle =>
          println("  [Session Idle]")
        case SessionEventType.SessionError =>
          val msg = event.data.hcursor.get[String]("message").getOrElse("unknown error")
          println(s"  [Error] $msg")
        case _ =>
          () // ignore other events
    }

    // -----------------------------------------------------------------------
    // 7. Send a message and wait for the response
    // -----------------------------------------------------------------------
    println("\nSending message...")
    val response = Await.result(
      session.sendAndWait(MessageOptions(
        prompt = "What is the weather in San Francisco?"
      )),
      120.seconds
    )

    response match
      case Some(event) =>
        val content = event.data.hcursor.get[String]("content").getOrElse("")
        println(s"\nFinal response: $content")
      case None =>
        println("\nNo assistant message received.")

    // -----------------------------------------------------------------------
    // 8. Send another message (conversation continues)
    // -----------------------------------------------------------------------
    println("\nSending follow-up message...")
    val followUp = Await.result(
      session.sendAndWait(MessageOptions(
        prompt = "What about New York?"
      )),
      120.seconds
    )

    followUp match
      case Some(event) =>
        val content = event.data.hcursor.get[String]("content").getOrElse("")
        println(s"\nFollow-up response: $content")
      case None =>
        println("\nNo follow-up response received.")

    // -----------------------------------------------------------------------
    // 9. Get message history
    // -----------------------------------------------------------------------
    val messages = Await.result(session.getMessages(), 10.seconds)
    println(s"\nSession has ${messages.size} events in history.")

    // -----------------------------------------------------------------------
    // 10. Clean up
    // -----------------------------------------------------------------------
    println("\nDestroying session...")
    Await.result(session.destroy(), 10.seconds)
    println("Session destroyed.")

  finally
    println("Stopping client...")
    val errors = client.stop()
    if errors.nonEmpty then
      println(s"Cleanup errors: ${errors.map(_.getMessage).mkString(", ")}")
    else
      println("Client stopped cleanly.")
