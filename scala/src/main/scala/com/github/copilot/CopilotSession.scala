// Copyright (c) Microsoft Corporation. All rights reserved.

package com.github.copilot

import io.circe.*
import io.circe.parser.*
import io.circe.syntax.*

import java.util.concurrent.ConcurrentHashMap
import scala.collection.mutable
import scala.concurrent.{ExecutionContext, Future, Promise}
import scala.concurrent.duration.*
import scala.jdk.CollectionConverters.*
import scala.util.{Failure, Success, Try}

/**
 * Represents a single conversation session with the Copilot CLI.
 *
 * A session maintains conversation state, handles events, and manages tool execution.
 * Sessions are created via [[CopilotClient.createSession]] or resumed via
 * [[CopilotClient.resumeSession]].
 *
 * == Usage ==
 * {{{
 * val session = Await.result(client.createSession(), 30.seconds)
 *
 * // Subscribe to events
 * val unsub = session.on { event =>
 *   if event.`type` == SessionEventType.AssistantMessage then
 *     println(s"Assistant: ${event.data}")
 * }
 *
 * // Send and wait
 * val response = Await.result(
 *   session.sendAndWait(MessageOptions(prompt = "Hello!")),
 *   60.seconds
 * )
 *
 * unsub() // unsubscribe
 * Await.result(session.destroy(), 10.seconds)
 * }}}
 *
 * @param sessionId     The unique session identifier
 * @param connection    The JSON-RPC client for server communication
 * @param workspacePath Path to the workspace directory (when infinite sessions enabled)
 */
class CopilotSession(
  val sessionId: String,
  private val connection: JsonRpcClient,
  val workspacePath: Option[String] = None
)(using ec: ExecutionContext):

  // Event handlers
  private val eventHandlers = java.util.Collections.newSetFromMap(
    new ConcurrentHashMap[SessionEvent => Unit, java.lang.Boolean]()
  )
  private val typedEventHandlers = new ConcurrentHashMap[String, mutable.Set[SessionEvent => Unit]]()

  // Tool handlers
  private val toolHandlers = new ConcurrentHashMap[String, ToolHandler]()

  // Permission, user input, and hooks handlers
  @volatile private var permissionHandler: Option[PermissionHandler] = None
  @volatile private var userInputHandler: Option[UserInputHandler] = None
  @volatile private var hooks: Option[SessionHooks] = None

  // -------------------------------------------------------------------------
  // Sending Messages
  // -------------------------------------------------------------------------

  /**
   * Sends a message to the session.
   *
   * The message is enqueued for processing. Events are dispatched to registered handlers
   * as the assistant processes the message.
   *
   * @param options The message options
   * @return A Future with the message ID
   */
  def send(options: MessageOptions): Future[String] =
    val params = Json.obj(
      "sessionId" -> sessionId.asJson,
      "prompt" -> options.prompt.asJson,
      "attachments" -> options.attachments.asJson,
      "mode" -> options.mode.asJson,
      "responseFormat" -> options.responseFormat.asJson,
      "imageOptions" -> options.imageOptions.asJson,
    ).dropNullValues

    connection.sendRequest("session.send", params).map { result =>
      result.hcursor.get[String]("messageId").getOrElse(
        throw new RuntimeException("session.send response missing messageId")
      )
    }

  /**
   * Sends a message and waits until the session becomes idle.
   *
   * This is a convenience method that combines [[send]] with waiting for the
   * `session.idle` event. Events are still delivered to registered handlers while waiting.
   *
   * @param options The message options
   * @param timeout Maximum time to wait (default: 60 seconds)
   * @return A Future with the last assistant.message event, or None if no assistant message was received
   */
  def sendAndWait(
    options: MessageOptions,
    timeout: FiniteDuration = 60.seconds
  ): Future[Option[SessionEvent]] =
    val idlePromise = Promise[Option[SessionEvent]]()
    @volatile var lastAssistantMessage: Option[SessionEvent] = None

    // Register event handler BEFORE calling send to avoid race condition
    val unsubscribe = on { event =>
      event.`type` match
        case SessionEventType.AssistantMessage =>
          lastAssistantMessage = Some(event)
        case SessionEventType.SessionIdle =>
          idlePromise.trySuccess(lastAssistantMessage)
        case SessionEventType.SessionError =>
          val errorMsg = event.data.hcursor.get[String]("message").getOrElse("Unknown error")
          val errorStack = event.data.hcursor.get[String]("stack").toOption
          val ex = new RuntimeException(errorMsg)
          errorStack.foreach(s => ex.setStackTrace(Array.empty)) // stack from server
          idlePromise.tryFailure(ex)
        case _ => // ignore other events
    }

    // Create timeout Future
    val timeoutFuture = Future:
      Thread.sleep(timeout.toMillis)
      throw new java.util.concurrent.TimeoutException(
        s"Timeout after ${timeout.toMillis}ms waiting for session.idle"
      )

    val resultFuture = send(options).flatMap { _ =>
      Future.firstCompletedOf(Seq(idlePromise.future, timeoutFuture))
    }

    // Clean up on completion
    resultFuture.andThen { case _ => unsubscribe() }

  // -------------------------------------------------------------------------
  // Event Subscriptions
  // -------------------------------------------------------------------------

  /**
   * Subscribes to all events from this session.
   *
   * @param handler Callback for all session events
   * @return An unsubscribe function
   */
  def on(handler: SessionEvent => Unit): () => Unit =
    eventHandlers.add(handler)
    () => eventHandlers.remove(handler)

  /**
   * Subscribes to a specific event type.
   *
   * @param eventType The event type string (e.g., SessionEventType.AssistantMessage)
   * @param handler   Callback for matching events
   * @return An unsubscribe function
   */
  def on(eventType: String, handler: SessionEvent => Unit): () => Unit =
    typedEventHandlers
      .computeIfAbsent(eventType, _ => mutable.Set.empty)
      .addOne(handler)
    () =>
      val handlers = typedEventHandlers.get(eventType)
      if handlers != null then handlers.remove(handler)

  // -------------------------------------------------------------------------
  // Message History
  // -------------------------------------------------------------------------

  /**
   * Retrieves all events and messages from this session's history.
   *
   * @return A Future with all session events
   */
  def getMessages(): Future[List[SessionEvent]] =
    connection.sendRequest("session.getMessages", Json.obj("sessionId" -> sessionId.asJson)).flatMap { result =>
      result.hcursor.get[List[SessionEvent]]("events") match
        case Right(events) => Future.successful(events)
        case Left(err) => Future.failed(new RuntimeException(s"Failed to decode messages: $err"))
    }

  // -------------------------------------------------------------------------
  // Session Lifecycle
  // -------------------------------------------------------------------------

  /**
   * Destroys this session and releases all associated resources.
   *
   * After calling this, the session can no longer be used. To continue the conversation,
   * use [[CopilotClient.resumeSession]] with the session ID.
   */
  def destroy(): Future[Unit] =
    connection.sendRequest("session.destroy", Json.obj("sessionId" -> sessionId.asJson)).map { _ =>
      eventHandlers.clear()
      typedEventHandlers.clear()
      toolHandlers.clear()
      permissionHandler = None
      userInputHandler = None
      hooks = None
    }

  /**
   * Aborts the currently processing message.
   *
   * The session remains valid and can be used for new messages.
   */
  def abort(): Future[Unit] =
    connection.sendRequest("session.abort", Json.obj("sessionId" -> sessionId.asJson)).map(_ => ())

  // -------------------------------------------------------------------------
  // Tool Registration (internal)
  // -------------------------------------------------------------------------

  /** Registers tool handlers. Called internally by CopilotClient. */
  private[copilot] def registerTools(tools: List[Tool]): Unit =
    toolHandlers.clear()
    tools.foreach(t => toolHandlers.put(t.name, t.handler))

  /** Gets a registered tool handler by name. */
  private[copilot] def getToolHandler(name: String): Option[ToolHandler] =
    Option(toolHandlers.get(name))

  /** Registers a permission handler. */
  private[copilot] def registerPermissionHandler(handler: PermissionHandler): Unit =
    permissionHandler = Some(handler)

  /** Registers a user input handler. */
  private[copilot] def registerUserInputHandler(handler: UserInputHandler): Unit =
    userInputHandler = Some(handler)

  /** Registers session hooks. */
  private[copilot] def registerHooks(h: SessionHooks): Unit =
    hooks = Some(h)

  // -------------------------------------------------------------------------
  // Event Dispatch (internal)
  // -------------------------------------------------------------------------

  /** Dispatches an event to all registered handlers. Called by CopilotClient. */
  private[copilot] def dispatchEvent(event: SessionEvent): Unit =
    // Typed handlers
    val typedSet = typedEventHandlers.get(event.`type`)
    if typedSet != null then
      typedSet.foreach { handler =>
        Try(handler(event)).failed.foreach(_ => ()) // ignore handler errors
      }
    // Wildcard handlers
    eventHandlers.forEach { handler =>
      Try(handler(event)).failed.foreach(_ => ()) // ignore handler errors
    }

  // -------------------------------------------------------------------------
  // Request Handlers (internal, called by CopilotClient)
  // -------------------------------------------------------------------------

  /** Handles a permission request from the server. */
  private[copilot] def handlePermissionRequest(requestJson: Json): Future[PermissionRequestResult] =
    permissionHandler match
      case None =>
        Future.successful(PermissionRequestResult(
          kind = PermissionRequestResult.DeniedNoApprovalRule
        ))
      case Some(handler) =>
        requestJson.as[PermissionRequest] match
          case Left(_) =>
            Future.successful(PermissionRequestResult(
              kind = PermissionRequestResult.DeniedNoApprovalRule
            ))
          case Right(request) =>
            handler(request, PermissionInvocation(sessionId)).recover {
              case _ => PermissionRequestResult(
                kind = PermissionRequestResult.DeniedNoApprovalRule
              )
            }

  /** Handles a user input request from the server. */
  private[copilot] def handleUserInputRequest(request: UserInputRequest): Future[Json] =
    userInputHandler match
      case None =>
        Future.failed(new RuntimeException("User input requested but no handler registered"))
      case Some(handler) =>
        handler(request, UserInputInvocation(sessionId)).map(_.asJson)

  /** Handles a hooks invocation from the server. */
  private[copilot] def handleHooksInvoke(hookType: String, input: Json): Future[Option[Json]] =
    hooks match
      case None => Future.successful(None)
      case Some(h) =>
        val invocation = HookInvocation(sessionId)
        hookType match
          case "preToolUse" =>
            h.onPreToolUse match
              case None => Future.successful(None)
              case Some(handler) =>
                input.as[PreToolUseHookInput] match
                  case Left(_) => Future.successful(None)
                  case Right(parsed) =>
                    handler(parsed, invocation).map(_.map(_.asJson)).recover { case _ => None }

          case "postToolUse" =>
            h.onPostToolUse match
              case None => Future.successful(None)
              case Some(handler) =>
                input.as[PostToolUseHookInput] match
                  case Left(_) => Future.successful(None)
                  case Right(parsed) =>
                    handler(parsed, invocation).map(_.map(_.asJson)).recover { case _ => None }

          case "userPromptSubmitted" =>
            h.onUserPromptSubmitted match
              case None => Future.successful(None)
              case Some(handler) =>
                input.as[UserPromptSubmittedHookInput] match
                  case Left(_) => Future.successful(None)
                  case Right(parsed) =>
                    handler(parsed, invocation).map(_.map(_.asJson)).recover { case _ => None }

          case "sessionStart" =>
            h.onSessionStart match
              case None => Future.successful(None)
              case Some(handler) =>
                input.as[SessionStartHookInput] match
                  case Left(_) => Future.successful(None)
                  case Right(parsed) =>
                    handler(parsed, invocation).map(_.map(_.asJson)).recover { case _ => None }

          case "sessionEnd" =>
            h.onSessionEnd match
              case None => Future.successful(None)
              case Some(handler) =>
                input.as[SessionEndHookInput] match
                  case Left(_) => Future.successful(None)
                  case Right(parsed) =>
                    handler(parsed, invocation).map(_.map(_.asJson)).recover { case _ => None }

          case "errorOccurred" =>
            h.onErrorOccurred match
              case None => Future.successful(None)
              case Some(handler) =>
                input.as[ErrorOccurredHookInput] match
                  case Left(_) => Future.successful(None)
                  case Right(parsed) =>
                    handler(parsed, invocation).map(_.map(_.asJson)).recover { case _ => None }

          case _ => Future.successful(None)
