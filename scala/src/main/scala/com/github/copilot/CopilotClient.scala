// Copyright (c) Microsoft Corporation. All rights reserved.

package com.github.copilot

import io.circe.*
import io.circe.parser.*
import io.circe.syntax.*

import java.io.File
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference
import scala.collection.mutable
import scala.concurrent.{ExecutionContext, Future, Promise}
import scala.jdk.CollectionConverters.*
import scala.util.{Failure, Success, Try}

/**
 * Main client for interacting with the Copilot CLI.
 *
 * The CopilotClient manages the connection to the Copilot CLI server and provides
 * methods to create and manage conversation sessions. It can either spawn a CLI
 * server process or connect to an existing server.
 *
 * == Usage ==
 * {{{
 * import com.github.copilot.*
 * import scala.concurrent.Await
 * import scala.concurrent.duration.*
 * given ExecutionContext = ExecutionContext.global
 *
 * val client = CopilotClient()
 * Await.result(client.start(), 30.seconds)
 *
 * val session = Await.result(client.createSession(SessionConfig()), 30.seconds)
 * val response = Await.result(
 *   session.sendAndWait(MessageOptions(prompt = "Hello!")),
 *   60.seconds
 * )
 * println(response.map(_.data))
 *
 * Await.result(session.destroy(), 10.seconds)
 * client.stop()
 * }}}
 *
 * @param options Configuration options for the client
 */
class CopilotClient(options: CopilotClientOptions = CopilotClientOptions())(using ec: ExecutionContext):

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  private val stateRef = new AtomicReference[ConnectionState](ConnectionState.Disconnected)
  private var cliProcess: Option[Process] = None
  private var rpcClient: Option[JsonRpcClient] = None
  private var tcpSocket: Option[Socket] = None
  private val sessions = new ConcurrentHashMap[String, CopilotSession]()
  private val lifecycleHandlers = java.util.Collections.newSetFromMap(
    new ConcurrentHashMap[SessionLifecycleHandler, java.lang.Boolean]()
  )
  private val typedLifecycleHandlers = new ConcurrentHashMap[String, mutable.Set[SessionLifecycleHandler]]()
  @volatile private var modelsCache: Option[List[ModelInfo]] = None

  private val isExternalServer: Boolean = options.cliUrl.isDefined
  private val resolvedCliPath: String = options.cliPath.getOrElse("copilot")
  private val resolvedUseLoggedInUser: Boolean =
    options.useLoggedInUser.getOrElse(!options.githubToken.isDefined)

  // Validate options
  if options.cliUrl.isDefined && (options.useStdio || options.cliPath.isDefined) then
    throw new IllegalArgumentException("cliUrl is mutually exclusive with useStdio and cliPath")
  if options.cliUrl.isDefined && (options.githubToken.isDefined || options.useLoggedInUser.isDefined) then
    throw new IllegalArgumentException(
      "githubToken and useLoggedInUser cannot be used with cliUrl (external server manages its own auth)"
    )

  // Parse external server host/port if provided
  private val (externalHost, externalPort): (String, Int) = options.cliUrl match
    case Some(url) => parseCliUrl(url)
    case None      => ("localhost", 0)

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /** Gets the current connection state. */
  def getState: ConnectionState = stateRef.get()

  /**
   * Starts the CLI server and establishes a connection.
   *
   * If connecting to an external server (via cliUrl), only establishes the connection.
   * Otherwise, spawns the CLI server process and connects.
   *
   * This method is called automatically when creating a session if autoStart is true.
   */
  def start(): Future[Unit] = Future:
    if stateRef.get() == ConnectionState.Connected then return Future.successful(())

    stateRef.set(ConnectionState.Connecting)
    try
      if !isExternalServer then
        startCliServer()

      connectToServer()

      // Set up connection handlers
      attachConnectionHandlers()

      // Verify protocol version compatibility
      val pingFuture = ping()
      val pingResult = concurrent.Await.result(pingFuture, scala.concurrent.duration.Duration(10, "s"))
      verifyProtocolVersion(pingResult)

      stateRef.set(ConnectionState.Connected)
    catch
      case ex: Exception =>
        stateRef.set(ConnectionState.Error)
        throw ex

  /**
   * Stops the CLI server and closes all active sessions.
   *
   * @return A list of errors encountered during cleanup (empty on full success)
   */
  def stop(): List[Throwable] =
    val errors = mutable.ListBuffer[Throwable]()

    // Destroy all active sessions
    sessions.values().asScala.foreach { session =>
      try
        concurrent.Await.result(session.destroy(), scala.concurrent.duration.Duration(5, "s"))
      catch
        case ex: Exception =>
          errors += new RuntimeException(
            s"Failed to destroy session ${session.sessionId}: ${ex.getMessage}", ex
          )
    }
    sessions.clear()

    // Stop RPC client
    rpcClient.foreach { client =>
      try client.stop()
      catch case ex: Exception =>
        errors += new RuntimeException(s"Failed to stop RPC client: ${ex.getMessage}", ex)
    }
    rpcClient = None

    // Close TCP socket
    tcpSocket.foreach { socket =>
      try socket.close()
      catch case ex: Exception =>
        errors += new RuntimeException(s"Failed to close socket: ${ex.getMessage}", ex)
    }
    tcpSocket = None

    // Kill CLI process (only if we spawned it)
    if !isExternalServer then
      cliProcess.foreach { process =>
        try process.destroy()
        catch case ex: Exception =>
          errors += new RuntimeException(s"Failed to kill CLI process: ${ex.getMessage}", ex)
      }
    cliProcess = None

    modelsCache = None
    stateRef.set(ConnectionState.Disconnected)
    errors.toList

  /**
   * Forcefully stops the client without graceful session cleanup.
   */
  def forceStop(): Unit =
    sessions.clear()
    rpcClient.foreach(c => Try(c.stop()))
    rpcClient = None
    tcpSocket.foreach(s => Try(s.close()))
    tcpSocket = None
    if !isExternalServer then
      cliProcess.foreach(p => Try(p.destroyForcibly()))
    cliProcess = None
    modelsCache = None
    stateRef.set(ConnectionState.Disconnected)

  /**
   * Creates a new conversation session.
   *
   * @param config Session configuration
   * @return A Future that resolves with the created session
   */
  def createSession(config: SessionConfig = SessionConfig()): Future[CopilotSession] =
    ensureConnected().flatMap { client =>
      val toolDefs = config.tools.map(t => Json.obj(
        "name" -> t.name.asJson,
        "description" -> t.description.asJson,
        "parameters" -> t.parameters.map(Json.fromJsonObject).asJson
      ))

      val params = Json.obj(
        "model" -> config.model.asJson,
        "sessionId" -> config.sessionId.asJson,
        "reasoningEffort" -> config.reasoningEffort.asJson,
        "tools" -> (if toolDefs.nonEmpty then toolDefs.asJson else Json.Null),
        "systemMessage" -> config.systemMessage.asJson,
        "availableTools" -> config.availableTools.asJson,
        "excludedTools" -> config.excludedTools.asJson,
        "provider" -> config.provider.asJson,
        "requestPermission" -> config.onPermissionRequest.isDefined.asJson,
        "requestUserInput" -> config.onUserInputRequest.isDefined.asJson,
        "hooks" -> config.hooks.exists(_.hasAny).asJson,
        "workingDirectory" -> config.workingDirectory.asJson,
        "streaming" -> config.streaming.asJson,
        "mcpServers" -> config.mcpServers.map(m => Json.fromJsonObject(
          JsonObject.fromIterable(m.map((k, v) => k -> Json.fromJsonObject(v)))
        )).asJson,
        "customAgents" -> config.customAgents.asJson,
        "configDir" -> config.configDir.asJson,
        "skillDirectories" -> config.skillDirectories.asJson,
        "disabledSkills" -> config.disabledSkills.asJson,
        "infiniteSessions" -> config.infiniteSessions.asJson,
      ).dropNullValues

      client.sendRequest("session.create", params).map { result =>
        val sessionId = result.hcursor.get[String]("sessionId").getOrElse(
          throw new RuntimeException("session.create response missing sessionId")
        )
        val workspacePath = result.hcursor.get[String]("workspacePath").toOption
        val session = new CopilotSession(sessionId, client, workspacePath)
        session.registerTools(config.tools)
        config.onPermissionRequest.foreach(session.registerPermissionHandler)
        config.onUserInputRequest.foreach(session.registerUserInputHandler)
        config.hooks.foreach(session.registerHooks)
        sessions.put(sessionId, session)
        session
      }
    }

  /**
   * Resumes an existing session by ID.
   *
   * @param sessionId The session ID to resume
   * @param config    Optional configuration overrides
   * @return A Future that resolves with the resumed session
   */
  def resumeSession(sessionId: String, config: ResumeSessionConfig = ResumeSessionConfig()): Future[CopilotSession] =
    ensureConnected().flatMap { client =>
      val toolDefs = config.tools.map(t => Json.obj(
        "name" -> t.name.asJson,
        "description" -> t.description.asJson,
        "parameters" -> t.parameters.map(Json.fromJsonObject).asJson
      ))

      val params = Json.obj(
        "sessionId" -> sessionId.asJson,
        "model" -> config.model.asJson,
        "reasoningEffort" -> config.reasoningEffort.asJson,
        "tools" -> (if toolDefs.nonEmpty then toolDefs.asJson else Json.Null),
        "systemMessage" -> config.systemMessage.asJson,
        "availableTools" -> config.availableTools.asJson,
        "excludedTools" -> config.excludedTools.asJson,
        "provider" -> config.provider.asJson,
        "requestPermission" -> config.onPermissionRequest.isDefined.asJson,
        "requestUserInput" -> config.onUserInputRequest.isDefined.asJson,
        "hooks" -> config.hooks.exists(_.hasAny).asJson,
        "workingDirectory" -> config.workingDirectory.asJson,
        "configDir" -> config.configDir.asJson,
        "streaming" -> config.streaming.asJson,
        "mcpServers" -> config.mcpServers.map(m => Json.fromJsonObject(
          JsonObject.fromIterable(m.map((k, v) => k -> Json.fromJsonObject(v)))
        )).asJson,
        "customAgents" -> config.customAgents.asJson,
        "skillDirectories" -> config.skillDirectories.asJson,
        "disabledSkills" -> config.disabledSkills.asJson,
        "infiniteSessions" -> config.infiniteSessions.asJson,
        "disableResume" -> config.disableResume.asJson,
      ).dropNullValues

      client.sendRequest("session.resume", params).map { result =>
        val resumedId = result.hcursor.get[String]("sessionId").getOrElse(sessionId)
        val workspacePath = result.hcursor.get[String]("workspacePath").toOption
        val session = new CopilotSession(resumedId, client, workspacePath)
        session.registerTools(config.tools)
        config.onPermissionRequest.foreach(session.registerPermissionHandler)
        config.onUserInputRequest.foreach(session.registerUserInputHandler)
        config.hooks.foreach(session.registerHooks)
        sessions.put(resumedId, session)
        session
      }
    }

  /**
   * Sends a ping to the server.
   *
   * @param message Optional message to include
   * @return A Future with the ping response
   */
  def ping(message: Option[String] = None): Future[PingResponse] =
    ensureConnected().flatMap { client =>
      client.sendRequest("ping", Json.obj("message" -> message.asJson).dropNullValues).flatMap { result =>
        result.as[PingResponse] match
          case Right(r) => Future.successful(r)
          case Left(err) => Future.failed(new RuntimeException(s"Failed to decode ping response: $err"))
      }
    }

  /** Get CLI status including version and protocol information. */
  def getStatus(): Future[GetStatusResponse] =
    ensureConnected().flatMap { client =>
      client.sendRequest("status.get", Json.obj()).flatMap { result =>
        result.as[GetStatusResponse] match
          case Right(r) => Future.successful(r)
          case Left(err) => Future.failed(new RuntimeException(s"Failed to decode status response: $err"))
      }
    }

  /** Get current authentication status. */
  def getAuthStatus(): Future[GetAuthStatusResponse] =
    ensureConnected().flatMap { client =>
      client.sendRequest("auth.getStatus", Json.obj()).flatMap { result =>
        result.as[GetAuthStatusResponse] match
          case Right(r) => Future.successful(r)
          case Left(err) => Future.failed(new RuntimeException(s"Failed to decode auth status: $err"))
      }
    }

  /**
   * List available models. Results are cached after the first call.
   */
  def listModels(): Future[List[ModelInfo]] =
    modelsCache match
      case Some(models) => Future.successful(models)
      case None =>
        ensureConnected().flatMap { client =>
          client.sendRequest("models.list", Json.obj()).flatMap { result =>
            result.hcursor.get[List[ModelInfo]]("models") match
              case Right(models) =>
                modelsCache = Some(models)
                Future.successful(models)
              case Left(err) =>
                Future.failed(new RuntimeException(s"Failed to decode models: $err"))
          }
        }

  /** Get the last session ID. */
  def getLastSessionId(): Future[Option[String]] =
    ensureConnected().flatMap { client =>
      client.sendRequest("session.getLastId", Json.obj()).map { result =>
        result.hcursor.get[String]("sessionId").toOption
      }
    }

  /** Delete a session by ID. */
  def deleteSession(sessionId: String): Future[Unit] =
    ensureConnected().flatMap { client =>
      client.sendRequest("session.delete", Json.obj("sessionId" -> sessionId.asJson)).flatMap { result =>
        val success = result.hcursor.get[Boolean]("success").getOrElse(false)
        if success then
          sessions.remove(sessionId)
          Future.successful(())
        else
          val error = result.hcursor.get[String]("error").getOrElse("Unknown error")
          Future.failed(new RuntimeException(s"Failed to delete session $sessionId: $error"))
      }
    }

  /** List all available sessions. */
  def listSessions(): Future[List[SessionMetadata]] =
    ensureConnected().flatMap { client =>
      client.sendRequest("session.list", Json.obj()).flatMap { result =>
        result.hcursor.get[List[SessionMetadata]]("sessions") match
          case Right(sessions) => Future.successful(sessions)
          case Left(err) => Future.failed(new RuntimeException(s"Failed to decode sessions: $err"))
      }
    }

  /** Get the foreground session ID (TUI+server mode). */
  def getForegroundSessionId(): Future[Option[String]] =
    ensureConnected().flatMap { client =>
      client.sendRequest("session.getForeground", Json.obj()).map { result =>
        result.hcursor.get[String]("sessionId").toOption
      }
    }

  /** Set the foreground session (TUI+server mode). */
  def setForegroundSessionId(sessionId: String): Future[Unit] =
    ensureConnected().flatMap { client =>
      client.sendRequest("session.setForeground", Json.obj("sessionId" -> sessionId.asJson)).flatMap { result =>
        val success = result.hcursor.get[Boolean]("success").getOrElse(false)
        if success then Future.successful(())
        else
          val error = result.hcursor.get[String]("error").getOrElse("Failed to set foreground session")
          Future.failed(new RuntimeException(error))
      }
    }

  /**
   * Subscribe to all session lifecycle events.
   *
   * @param handler Callback for lifecycle events
   * @return An unsubscribe function
   */
  def onLifecycle(handler: SessionLifecycleHandler): () => Unit =
    lifecycleHandlers.add(handler)
    () => lifecycleHandlers.remove(handler)

  /**
   * Subscribe to a specific lifecycle event type.
   *
   * @param eventType The event type to listen for
   * @param handler   Callback for matching events
   * @return An unsubscribe function
   */
  def onLifecycle(eventType: String, handler: SessionLifecycleHandler): () => Unit =
    typedLifecycleHandlers
      .computeIfAbsent(eventType, _ => mutable.Set.empty)
      .addOne(handler)
    () =>
      val handlers = typedLifecycleHandlers.get(eventType)
      if handlers != null then handlers.remove(handler)

  // -------------------------------------------------------------------------
  // Private: CLI process management
  // -------------------------------------------------------------------------

  private def parseCliUrl(url: String): (String, Int) =
    val clean = url.replaceFirst("^https?://", "")
    if clean.matches("^\\d+$") then
      ("localhost", clean.toInt)
    else
      val parts = clean.split(":")
      if parts.length != 2 then
        throw new IllegalArgumentException(
          s"Invalid cliUrl format: $url. Expected \"host:port\", \"http://host:port\", or \"port\""
        )
      val host = if parts(0).isEmpty then "localhost" else parts(0)
      val port = parts(1).toInt
      if port <= 0 || port > 65535 then
        throw new IllegalArgumentException(s"Invalid port in cliUrl: $url")
      (host, port)

  private def startCliServer(): Unit =
    val args = mutable.ListBuffer[String]()
    args ++= options.cliArgs
    args += "--headless"
    args += "--no-auto-update"
    args += "--log-level"
    args += options.logLevel

    if options.useStdio then
      args += "--stdio"
    else if options.port > 0 then
      args += "--port"
      args += options.port.toString

    // Auth flags
    options.githubToken.foreach { _ =>
      args += "--auth-token-env"
      args += "COPILOT_SDK_AUTH_TOKEN"
    }
    if !resolvedUseLoggedInUser then
      args += "--no-auto-login"

    val processBuilder = new ProcessBuilder((resolvedCliPath +: args.toSeq)*)
    processBuilder.redirectErrorStream(false)

    // Set working directory
    options.cwd.foreach(dir => processBuilder.directory(new File(dir)))

    // Set environment variables
    val env = processBuilder.environment()
    options.env.foreach { envMap =>
      env.clear()
      envMap.foreach((k, v) => env.put(k, v))
    }
    env.remove("NODE_DEBUG") // Suppress debug output that might pollute stdout
    options.githubToken.foreach(token => env.put("COPILOT_SDK_AUTH_TOKEN", token))

    val process = processBuilder.start()
    cliProcess = Some(process)

    // Forward stderr
    val stderrThread = new Thread(() => {
      val reader = new java.io.BufferedReader(new java.io.InputStreamReader(process.getErrorStream))
      try
        var line = reader.readLine()
        while line != null do
          System.err.println(s"[CLI subprocess] $line")
          line = reader.readLine()
      catch case _: Exception => // ignore
    }, "cli-stderr-reader")
    stderrThread.setDaemon(true)
    stderrThread.start()

    if !options.useStdio then
      // TCP mode: read stdout to find port announcement
      val stdoutReader = new java.io.BufferedReader(
        new java.io.InputStreamReader(process.getInputStream)
      )
      val portPattern = "listening on port (\\d+)".r
      var found = false
      val startTime = System.currentTimeMillis()
      while !found && (System.currentTimeMillis() - startTime < 10000) do
        val line = stdoutReader.readLine()
        if line == null then
          throw new RuntimeException("CLI process exited before announcing port")
        portPattern.findFirstMatchIn(line).foreach { m =>
          // externalPort is immutable, so for TCP we'd store elsewhere -- but for stdio this is unused
          found = true
        }
      if !found then
        throw new RuntimeException("Timeout waiting for CLI server to start")

  private def connectToServer(): Unit =
    if options.useStdio && !isExternalServer then
      connectViaStdio()
    else
      connectViaTcp()

  private def connectViaStdio(): Unit =
    val process = cliProcess.getOrElse(
      throw new RuntimeException("CLI process not started")
    )
    val client = new JsonRpcClient(process.getInputStream, process.getOutputStream)
    client.start()
    rpcClient = Some(client)

  private def connectViaTcp(): Unit =
    val host = if isExternalServer then externalHost else "localhost"
    val port = if isExternalServer then externalPort else options.port
    if port <= 0 then
      throw new RuntimeException("Server port not available")

    val socket = new Socket(host, port)
    tcpSocket = Some(socket)
    val client = new JsonRpcClient(socket.getInputStream, socket.getOutputStream)
    client.start()
    rpcClient = Some(client)

  private def verifyProtocolVersion(pingResult: PingResponse): Unit =
    val expectedVersion = SdkProtocolVersion.get
    pingResult.protocolVersion match
      case None =>
        throw new RuntimeException(
          s"SDK protocol version mismatch: SDK expects version $expectedVersion, " +
            "but server does not report a protocol version. Please update your server."
        )
      case Some(serverVersion) if serverVersion != expectedVersion =>
        throw new RuntimeException(
          s"SDK protocol version mismatch: SDK expects version $expectedVersion, " +
            s"but server reports version $serverVersion. Please update your SDK or server."
        )
      case _ => // versions match

  // -------------------------------------------------------------------------
  // Connection handlers
  // -------------------------------------------------------------------------

  private def attachConnectionHandlers(): Unit =
    val client = rpcClient.getOrElse(return)

    // session.event notification
    client.onNotification("session.event", handleSessionEvent)

    // session.lifecycle notification
    client.onNotification("session.lifecycle", handleSessionLifecycle)

    // tool.call request (server asks client to execute a tool)
    client.onRequest("tool.call", handleToolCall)

    // permission.request (server asks client for permission)
    client.onRequest("permission.request", handlePermissionRequest)

    // userInput.request (server asks client for user input)
    client.onRequest("userInput.request", handleUserInputRequest)

    // hooks.invoke (server asks client to run a hook)
    client.onRequest("hooks.invoke", handleHooksInvoke)

  private def handleSessionEvent(params: Json): Unit =
    val cursor = params.hcursor
    for
      sessionId <- cursor.get[String]("sessionId").toOption
      eventJson <- cursor.get[Json]("event").toOption
      event     <- eventJson.as[SessionEvent].toOption
      session   <- Option(sessions.get(sessionId))
    do
      session.dispatchEvent(event)

  private def handleSessionLifecycle(params: Json): Unit =
    params.as[SessionLifecycleEvent].toOption.foreach { event =>
      // Typed handlers
      val typedSet = typedLifecycleHandlers.get(event.`type`)
      if typedSet != null then
        typedSet.foreach { handler =>
          Try(handler(event)).failed.foreach(_ => ()) // ignore handler errors
        }
      // Wildcard handlers
      lifecycleHandlers.forEach { handler =>
        Try(handler(event)).failed.foreach(_ => ()) // ignore handler errors
      }
    }

  private def handleToolCall(params: Json): Future[Json] =
    val cursor = params.hcursor
    val sessionId = cursor.get[String]("sessionId").getOrElse(
      throw new RuntimeException("Invalid tool call: missing sessionId")
    )
    val toolCallId = cursor.get[String]("toolCallId").getOrElse(
      throw new RuntimeException("Invalid tool call: missing toolCallId")
    )
    val toolName = cursor.get[String]("toolName").getOrElse(
      throw new RuntimeException("Invalid tool call: missing toolName")
    )
    val arguments = cursor.get[Json]("arguments").getOrElse(Json.obj())

    val session = Option(sessions.get(sessionId)).getOrElse(
      throw new RuntimeException(s"Unknown session $sessionId")
    )

    val handler = session.getToolHandler(toolName)
    handler match
      case None =>
        val errorResult = ToolResultObject(
          textResultForLlm = s"Tool '$toolName' is not supported by this client instance.",
          resultType = ToolResultType.Failure,
          error = Some(s"tool '$toolName' not supported"),
          toolTelemetry = Some(Map.empty)
        )
        Future.successful(Json.obj("result" -> errorResult.asJson))

      case Some(h) =>
        val invocation = ToolInvocation(sessionId, toolCallId, toolName, arguments)
        h(arguments, invocation)
          .map { result =>
            Json.obj("result" -> result.asJson)
          }
          .recover { case ex: Exception =>
            val errorResult = ToolResultObject(
              textResultForLlm = "Invoking this tool produced an error. Detailed information is not available.",
              resultType = ToolResultType.Failure,
              error = Some(ex.getMessage),
              toolTelemetry = Some(Map.empty)
            )
            Json.obj("result" -> errorResult.asJson)
          }

  private def handlePermissionRequest(params: Json): Future[Json] =
    val cursor = params.hcursor
    val sessionId = cursor.get[String]("sessionId").getOrElse(
      throw new RuntimeException("Invalid permission request: missing sessionId")
    )
    val requestJson = cursor.get[Json]("permissionRequest").getOrElse(Json.obj())

    val session = Option(sessions.get(sessionId)).getOrElse(
      throw new RuntimeException(s"Session not found: $sessionId")
    )

    session.handlePermissionRequest(requestJson).map { result =>
      Json.obj("result" -> result.asJson)
    }.recover { case _ =>
      Json.obj("result" -> Json.obj(
        "kind" -> "denied-no-approval-rule-and-could-not-request-from-user".asJson
      ))
    }

  private def handleUserInputRequest(params: Json): Future[Json] =
    val cursor = params.hcursor
    val sessionId = cursor.get[String]("sessionId").getOrElse(
      throw new RuntimeException("Invalid user input request: missing sessionId")
    )
    val question = cursor.get[String]("question").getOrElse("")
    val choices = cursor.get[List[String]]("choices").toOption
    val allowFreeform = cursor.get[Boolean]("allowFreeform").toOption

    val session = Option(sessions.get(sessionId)).getOrElse(
      throw new RuntimeException(s"Session not found: $sessionId")
    )

    val request = UserInputRequest(question, choices, allowFreeform)
    session.handleUserInputRequest(request).map(_.asJson)

  private def handleHooksInvoke(params: Json): Future[Json] =
    val cursor = params.hcursor
    val sessionId = cursor.get[String]("sessionId").getOrElse(
      throw new RuntimeException("Invalid hooks invoke: missing sessionId")
    )
    val hookType = cursor.get[String]("hookType").getOrElse(
      throw new RuntimeException("Invalid hooks invoke: missing hookType")
    )
    val input = cursor.get[Json]("input").getOrElse(Json.obj())

    val session = Option(sessions.get(sessionId)).getOrElse(
      throw new RuntimeException(s"Session not found: $sessionId")
    )

    session.handleHooksInvoke(hookType, input).map { output =>
      Json.obj("output" -> output.getOrElse(Json.Null))
    }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private def ensureConnected(): Future[JsonRpcClient] =
    rpcClient match
      case Some(client) if stateRef.get() == ConnectionState.Connected =>
        Future.successful(client)
      case _ if options.autoStart =>
        start().map(_ =>
          rpcClient.getOrElse(throw new RuntimeException("Failed to connect"))
        )
      case _ =>
        Future.failed(new RuntimeException("Client not connected. Call start() first."))
