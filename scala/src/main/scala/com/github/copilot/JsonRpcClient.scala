// Copyright (c) Microsoft Corporation. All rights reserved.

package com.github.copilot

import io.circe.*
import io.circe.parser.*
import io.circe.syntax.*

import java.io.{BufferedReader, InputStream, InputStreamReader, OutputStream}
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import scala.concurrent.{ExecutionContext, Future, Promise}
import scala.util.{Failure, Success, Try}

// ============================================================================
// JSON-RPC 2.0 Message Types
// ============================================================================

/** JSON-RPC 2.0 error. */
case class JsonRpcError(code: Int, message: String, data: Option[Json] = None)

object JsonRpcError:
  given Encoder[JsonRpcError] = Encoder.instance { e =>
    Json.obj(
      "code" -> e.code.asJson,
      "message" -> e.message.asJson,
      "data" -> e.data.asJson
    ).dropNullValues
  }
  given Decoder[JsonRpcError] = Decoder.instance { c =>
    for
      code    <- c.get[Int]("code")
      message <- c.get[String]("message")
      data    <- c.get[Option[Json]]("data")
    yield JsonRpcError(code, message, data)
  }

/** Exception wrapping a JSON-RPC error. */
class JsonRpcException(val error: JsonRpcError)
  extends RuntimeException(s"JSON-RPC Error ${error.code}: ${error.message}")

/** JSON-RPC 2.0 request (or notification when id is None). */
private[copilot] case class JsonRpcRequest(
  jsonrpc: String = "2.0",
  id: Option[String],
  method: String,
  params: Json
)

private[copilot] object JsonRpcRequest:
  given Encoder[JsonRpcRequest] = Encoder.instance { r =>
    val base = Json.obj(
      "jsonrpc" -> r.jsonrpc.asJson,
      "method" -> r.method.asJson,
      "params" -> r.params
    )
    r.id match
      case Some(id) => base.deepMerge(Json.obj("id" -> id.asJson))
      case None     => base
  }

/** JSON-RPC 2.0 response. */
private[copilot] case class JsonRpcResponse(
  id: Option[String],
  result: Option[Json],
  error: Option[JsonRpcError]
)

private[copilot] object JsonRpcResponse:
  given Decoder[JsonRpcResponse] = Decoder.instance { c =>
    for
      id     <- c.get[Option[String]]("id")
      result <- c.get[Option[Json]]("result")
      error  <- c.get[Option[JsonRpcError]]("error")
    yield JsonRpcResponse(id, result, error)
  }

/** Incoming message from the server -- either a request/notification or a response. */
private[copilot] case class IncomingMessage(
  id: Option[Json],
  method: Option[String],
  params: Option[Json],
  result: Option[Json],
  error: Option[JsonRpcError]
):
  /** True when this is a request (has method + id). */
  def isRequest: Boolean = method.isDefined && id.isDefined && !id.contains(Json.Null)
  /** True when this is a notification (has method but no id). */
  def isNotification: Boolean = method.isDefined && (id.isEmpty || id.contains(Json.Null))
  /** True when this is a response (has id, no method). */
  def isResponse: Boolean = method.isEmpty && id.isDefined && !id.contains(Json.Null)

  def idString: Option[String] = id.flatMap(_.asString)

private[copilot] object IncomingMessage:
  given Decoder[IncomingMessage] = Decoder.instance { c =>
    for
      id     <- c.get[Option[Json]]("id")
      method <- c.get[Option[String]]("method")
      params <- c.get[Option[Json]]("params")
      result <- c.get[Option[Json]]("result")
      error  <- c.get[Option[JsonRpcError]]("error")
    yield IncomingMessage(id, method, params, result, error)
  }

// ============================================================================
// Request Handler Type
// ============================================================================

/**
 * A handler for incoming server-to-client requests.
 * Returns a Future of the result Json, or fails with a JsonRpcException on error.
 */
type RequestHandler = Json => Future[Json]

// ============================================================================
// JSON-RPC Client
// ============================================================================

/**
 * JSON-RPC 2.0 client using Content-Length header framing.
 *
 * This client communicates over stdio (or any pair of input/output streams) with
 * the Copilot CLI server. Messages are framed using the standard
 * `Content-Length: <n>\r\n\r\n<body>` protocol (same as LSP).
 *
 * @param input   The input stream to read server messages from
 * @param output  The output stream to write client messages to
 * @param ec      The execution context for asynchronous operations
 */
class JsonRpcClient(
  input: InputStream,
  output: OutputStream
)(using ec: ExecutionContext):

  // Pending request promises, keyed by request ID
  private val pendingRequests = new ConcurrentHashMap[String, Promise[Json]]()

  // Registered request handlers (for server-to-client requests)
  private val requestHandlers = new ConcurrentHashMap[String, RequestHandler]()

  // Lock for writing to the output stream
  private val writeLock = new Object()

  @volatile private var running = false
  @volatile private var readThread: Option[Thread] = None

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /** Start the background read loop. */
  def start(): Unit =
    if running then return
    running = true
    val thread = new Thread(() => readLoop(), "jsonrpc-read-loop")
    thread.setDaemon(true)
    readThread = Some(thread)
    thread.start()

  /** Stop the client and fail all pending requests. */
  def stop(): Unit =
    running = false
    readThread.foreach(_.interrupt())
    readThread = None
    // Fail all pending requests
    val error = new RuntimeException("JSON-RPC client stopped")
    pendingRequests.forEach { (_, promise) =>
      promise.tryFailure(error)
    }
    pendingRequests.clear()

  // -------------------------------------------------------------------------
  // Outbound: send requests and notifications
  // -------------------------------------------------------------------------

  /**
   * Send a JSON-RPC request and return a Future of the result.
   *
   * @param method  The RPC method name
   * @param params  The parameters as a circe Json value
   * @return        A Future that completes with the result Json
   */
  def sendRequest(method: String, params: Json): Future[Json] =
    val id = UUID.randomUUID().toString
    val promise = Promise[Json]()
    pendingRequests.put(id, promise)

    val request = JsonRpcRequest(id = Some(id), method = method, params = params)
    Try(writeMessage(request.asJson)) match
      case Failure(ex) =>
        pendingRequests.remove(id)
        promise.tryFailure(ex)
      case Success(_) => // message sent, waiting for response

    promise.future

  /**
   * Send a JSON-RPC notification (no response expected).
   *
   * @param method  The RPC method name
   * @param params  The parameters
   */
  def sendNotification(method: String, params: Json): Unit =
    val notification = JsonRpcRequest(id = None, method = method, params = params)
    writeMessage(notification.asJson)

  // -------------------------------------------------------------------------
  // Inbound: register handlers for server-initiated requests
  // -------------------------------------------------------------------------

  /**
   * Register a handler for incoming requests on the given method.
   * The handler receives the `params` Json and must return a Future[Json] result.
   */
  def onRequest(method: String, handler: RequestHandler): Unit =
    requestHandlers.put(method, handler)

  /**
   * Register a handler for incoming notifications on the given method.
   * Notifications are one-way; no response is sent.
   */
  def onNotification(method: String, handler: Json => Unit): Unit =
    requestHandlers.put(method, params =>
      handler(params)
      Future.successful(Json.Null) // notifications don't send responses
    )

  /**
   * Remove a previously registered request/notification handler.
   */
  def removeHandler(method: String): Unit =
    requestHandlers.remove(method)

  // -------------------------------------------------------------------------
  // Wire protocol: Content-Length header framing
  // -------------------------------------------------------------------------

  private def writeMessage(json: Json): Unit =
    val body = json.noSpaces.getBytes(StandardCharsets.UTF_8)
    val header = s"Content-Length: ${body.length}\r\n\r\n"
    writeLock.synchronized:
      output.write(header.getBytes(StandardCharsets.US_ASCII))
      output.write(body)
      output.flush()

  private def readLoop(): Unit =
    val reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8))
    try
      while running do
        // 1. Read headers until blank line
        val contentLength = readHeaders(reader)
        if contentLength <= 0 then
          // EOF or error
          running = false
        else
          // 2. Read exactly contentLength bytes
          val bodyChars = new Array[Char](contentLength)
          var totalRead = 0
          while totalRead < contentLength do
            val n = reader.read(bodyChars, totalRead, contentLength - totalRead)
            if n < 0 then
              running = false
              totalRead = contentLength // break
            else
              totalRead += n

          if running then
            val bodyStr = new String(bodyChars, 0, totalRead)
            handleIncomingMessage(bodyStr)
    catch
      case _: InterruptedException => // expected on stop
      case _: java.io.IOException if !running => // stream closed during shutdown
      case ex: Exception =>
        System.err.println(s"[JsonRpcClient] Read loop error: ${ex.getMessage}")
    finally
      running = false

  /**
   * Read HTTP-style headers and return the Content-Length value.
   * Returns -1 on EOF.
   */
  private def readHeaders(reader: BufferedReader): Int =
    var contentLength = -1
    var line = reader.readLine()
    if line == null then return -1 // EOF

    while line != null && line.nonEmpty do
      if line.startsWith("Content-Length:") then
        val value = line.substring("Content-Length:".length).trim
        Try(value.toInt).foreach(cl => contentLength = cl)
      line = reader.readLine()
      if line == null then return -1 // EOF before blank line

    contentLength

  // -------------------------------------------------------------------------
  // Message dispatch
  // -------------------------------------------------------------------------

  private def handleIncomingMessage(body: String): Unit =
    parse(body) match
      case Left(err) =>
        System.err.println(s"[JsonRpcClient] Failed to parse message: ${err.getMessage}")
      case Right(json) =>
        json.as[IncomingMessage] match
          case Left(err) =>
            System.err.println(s"[JsonRpcClient] Failed to decode message: ${err.getMessage}")
          case Right(msg) =>
            if msg.isResponse then
              handleResponse(msg)
            else if msg.isRequest then
              handleServerRequest(msg)
            else if msg.isNotification then
              handleServerNotification(msg)

  private def handleResponse(msg: IncomingMessage): Unit =
    msg.idString.foreach { id =>
      val promise = pendingRequests.remove(id)
      if promise != null then
        msg.error match
          case Some(err) => promise.tryFailure(JsonRpcException(err))
          case None      => promise.trySuccess(msg.result.getOrElse(Json.Null))
    }

  private def handleServerRequest(msg: IncomingMessage): Unit =
    val method = msg.method.getOrElse("")
    val params = msg.params.getOrElse(Json.obj())
    val requestId = msg.id.getOrElse(Json.Null)

    val handler = requestHandlers.get(method)
    if handler == null then
      // Method not found -- send error response
      sendErrorResponse(requestId, -32601, s"Method not found: $method")
    else
      // Execute handler asynchronously
      handler(params).onComplete:
        case Success(result) =>
          sendResultResponse(requestId, result)
        case Failure(ex: JsonRpcException) =>
          sendErrorResponse(requestId, ex.error.code, ex.error.message, ex.error.data)
        case Failure(ex) =>
          sendErrorResponse(requestId, -32603, s"Internal error: ${ex.getMessage}")

  private def handleServerNotification(msg: IncomingMessage): Unit =
    val method = msg.method.getOrElse("")
    val params = msg.params.getOrElse(Json.obj())
    val handler = requestHandlers.get(method)
    if handler != null then
      // Fire and forget -- notifications don't get responses
      handler(params).failed.foreach: ex =>
        System.err.println(s"[JsonRpcClient] Notification handler error for '$method': ${ex.getMessage}")

  private def sendResultResponse(id: Json, result: Json): Unit =
    val response = Json.obj(
      "jsonrpc" -> "2.0".asJson,
      "id" -> id,
      "result" -> result
    )
    Try(writeMessage(response)).failed.foreach: ex =>
      System.err.println(s"[JsonRpcClient] Failed to send response: ${ex.getMessage}")

  private def sendErrorResponse(id: Json, code: Int, message: String, data: Option[Json] = None): Unit =
    val errorObj = Json.obj(
      "code" -> code.asJson,
      "message" -> message.asJson,
      "data" -> data.asJson
    ).dropNullValues
    val response = Json.obj(
      "jsonrpc" -> "2.0".asJson,
      "id" -> id,
      "error" -> errorObj
    )
    Try(writeMessage(response)).failed.foreach: ex =>
      System.err.println(s"[JsonRpcClient] Failed to send error response: ${ex.getMessage}")
