/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

package com.github.copilot

import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Represents a single conversation session with the Copilot CLI.
 *
 * A session maintains conversation state, handles events, and manages tool execution.
 * Sessions are created via [CopilotClient.createSession] or resumed via
 * [CopilotClient.resumeSession].
 *
 * Example:
 * ```kotlin
 * val session = client.createSession(SessionConfig(model = "gpt-4"))
 *
 * session.on { event ->
 *     if (event.type == "assistant.message") {
 *         println(event.data)
 *     }
 * }
 *
 * val response = session.sendAndWait(MessageOptions(prompt = "Hello, world!"))
 * println(response?.data)
 *
 * session.destroy()
 * ```
 */
class CopilotSession internal constructor(
    /** The unique identifier for this session. */
    val sessionId: String,
    private val client: JsonRpcClient,
    private val scope: CoroutineScope,
    /**
     * Path to the session workspace directory when infinite sessions are enabled.
     * Contains checkpoints/, plan.md, and files/ subdirectories.
     * Null if infinite sessions are disabled.
     */
    val workspacePath: String? = null
) {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    private val eventHandlers = CopyOnWriteArrayList<SessionEventHandler>()
    private val typedEventHandlers = ConcurrentHashMap<String, CopyOnWriteArrayList<SessionEventHandler>>()
    private val toolHandlers = ConcurrentHashMap<String, ToolHandler>()

    @Volatile
    private var permissionHandler: PermissionHandler? = null

    @Volatile
    private var userInputHandler: UserInputHandler? = null

    @Volatile
    private var hooks: SessionHooks? = null

    /**
     * Sends a message to this session.
     *
     * The message is processed asynchronously. Subscribe to events via [on]
     * to receive streaming responses and other session events.
     *
     * @param options The message options including the prompt and optional attachments
     * @return The message ID
     */
    suspend fun send(options: MessageOptions): String {
        val params = buildJsonObject {
            put("sessionId", sessionId)
            put("prompt", options.prompt)
            options.attachments?.let {
                put("attachments", json.encodeToJsonElement(it))
            }
            options.mode?.let { put("mode", it) }
            options.responseFormat?.let { put("responseFormat", json.encodeToJsonElement(it)) }
            options.imageOptions?.let { put("imageOptions", json.encodeToJsonElement(it)) }
        }
        val response = client.request("session.send", params)
        return response.jsonObject["messageId"]!!.jsonPrimitive.content
    }

    /**
     * Sends a message and waits until the session becomes idle.
     *
     * This is a convenience method that combines [send] with waiting for
     * the `session.idle` event. Events are still delivered to handlers
     * registered via [on] while waiting.
     *
     * @param options The message options
     * @param timeoutMs Timeout in milliseconds (default: 60000). Controls how long to wait.
     * @return The final assistant message event, or null if no assistant message was received
     * @throws RuntimeException If the timeout is reached or a session error occurs
     */
    suspend fun sendAndWait(
        options: MessageOptions,
        timeoutMs: Long = 60_000L
    ): SessionEvent? {
        val idleDeferred = CompletableDeferred<Unit>()
        var lastAssistantMessage: SessionEvent? = null
        var sessionError: Exception? = null

        // Register event handler BEFORE calling send to avoid race conditions
        val unsubscribe = on { event ->
            when (event.type) {
                "assistant.message" -> lastAssistantMessage = event
                "session.idle" -> idleDeferred.complete(Unit)
                "session.error" -> {
                    val msg = event.data?.get("message")?.jsonPrimitive?.contentOrNull ?: "Unknown error"
                    sessionError = RuntimeException(msg)
                    idleDeferred.complete(Unit)
                }
            }
        }

        try {
            send(options)

            withTimeout(timeoutMs) {
                idleDeferred.await()
            }

            sessionError?.let { throw it }
            return lastAssistantMessage
        } finally {
            unsubscribe()
        }
    }

    /**
     * Subscribes to all events from this session.
     *
     * @param handler A callback function that receives all session events
     * @return A function that, when called, unsubscribes the handler
     */
    fun on(handler: SessionEventHandler): () -> Unit {
        eventHandlers.add(handler)
        return { eventHandlers.remove(handler) }
    }

    /**
     * Subscribes to a specific event type from this session.
     *
     * @param eventType The event type to listen for (e.g., "assistant.message", "session.idle")
     * @param handler A callback function that receives events of the specified type
     * @return A function that, when called, unsubscribes the handler
     */
    fun on(eventType: String, handler: SessionEventHandler): () -> Unit {
        typedEventHandlers.computeIfAbsent(eventType) { CopyOnWriteArrayList() }.add(handler)
        return {
            typedEventHandlers[eventType]?.remove(handler)
        }
    }

    /**
     * Retrieves all events and messages from this session's history.
     */
    suspend fun getMessages(): List<SessionEvent> {
        val response = client.request("session.getMessages", buildJsonObject {
            put("sessionId", sessionId)
        })
        val events = response.jsonObject["events"]?.jsonArray ?: return emptyList()
        return events.map { eventElement ->
            val obj = eventElement.jsonObject
            SessionEvent(
                type = obj["type"]?.jsonPrimitive?.content ?: "",
                data = obj["data"]?.jsonObject
            )
        }
    }

    /**
     * Destroys this session and releases all associated resources.
     *
     * After calling this method, the session can no longer be used.
     * To continue the conversation, use [CopilotClient.resumeSession].
     */
    suspend fun destroy() {
        client.request("session.destroy", buildJsonObject {
            put("sessionId", sessionId)
        })
        eventHandlers.clear()
        typedEventHandlers.clear()
        toolHandlers.clear()
        permissionHandler = null
        userInputHandler = null
        hooks = null
    }

    /**
     * Aborts the currently processing message in this session.
     *
     * The session remains valid and can continue to be used for new messages.
     */
    suspend fun abort() {
        client.request("session.abort", buildJsonObject {
            put("sessionId", sessionId)
        })
    }

    // ========================================================================
    // Internal Methods
    // ========================================================================

    /**
     * Registers custom tool handlers for this session.
     * @suppress
     */
    internal fun registerTools(tools: List<Tool>?) {
        toolHandlers.clear()
        tools?.forEach { tool ->
            toolHandlers[tool.name] = tool.handler
        }
    }

    /**
     * Retrieves a registered tool handler by name.
     * @suppress
     */
    internal fun getToolHandler(name: String): ToolHandler? = toolHandlers[name]

    /**
     * Registers a handler for permission requests.
     * @suppress
     */
    internal fun registerPermissionHandler(handler: PermissionHandler?) {
        this.permissionHandler = handler
    }

    /**
     * Registers a user input handler.
     * @suppress
     */
    internal fun registerUserInputHandler(handler: UserInputHandler?) {
        this.userInputHandler = handler
    }

    /**
     * Registers hook handlers.
     * @suppress
     */
    internal fun registerHooks(hooks: SessionHooks?) {
        this.hooks = hooks
    }

    /**
     * Dispatches a session event to all registered handlers.
     * @suppress
     */
    internal fun dispatchEvent(event: SessionEvent) {
        // Typed handlers
        typedEventHandlers[event.type]?.forEach { handler ->
            try {
                handler(event)
            } catch (_: Exception) {
                // Ignore handler errors
            }
        }

        // Wildcard handlers
        eventHandlers.forEach { handler ->
            try {
                handler(event)
            } catch (_: Exception) {
                // Ignore handler errors
            }
        }
    }

    /**
     * Handles a permission request from the server.
     * @suppress
     */
    internal suspend fun handlePermissionRequest(request: JsonObject): PermissionRequestResult {
        val handler = permissionHandler
            ?: return PermissionRequestResult(kind = "denied-no-approval-rule-and-could-not-request-from-user")

        return try {
            val permRequest = PermissionRequest(
                kind = request["kind"]?.jsonPrimitive?.content ?: "",
                toolCallId = request["toolCallId"]?.jsonPrimitive?.contentOrNull
            )
            handler(permRequest, sessionId)
        } catch (_: Exception) {
            PermissionRequestResult(kind = "denied-no-approval-rule-and-could-not-request-from-user")
        }
    }

    /**
     * Handles a user input request from the server.
     * @suppress
     */
    internal suspend fun handleUserInputRequest(request: UserInputRequest): UserInputResponse {
        val handler = userInputHandler
            ?: throw RuntimeException("User input requested but no handler registered")
        return handler(request, sessionId)
    }

    /**
     * Handles a hooks invocation from the server.
     * @suppress
     */
    @Suppress("UNCHECKED_CAST")
    internal suspend fun handleHooksInvoke(hookType: String, input: JsonElement?): Map<String, Any?>? {
        val currentHooks = hooks ?: return null
        val handler = currentHooks.getHandler(hookType) ?: return null

        val inputMap: Map<String, Any?> = if (input is JsonObject) {
            input.toMap().mapValues { (_, v) -> jsonElementToAny(v) }
        } else {
            emptyMap()
        }

        return try {
            handler(inputMap, sessionId)
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Converts a JsonElement to a Kotlin Any? value for hook input.
     */
    private fun jsonElementToAny(element: JsonElement): Any? = when (element) {
        is JsonNull -> null
        is JsonPrimitive -> when {
            element.isString -> element.content
            element.booleanOrNull != null -> element.boolean
            element.intOrNull != null -> element.int
            element.longOrNull != null -> element.long
            element.doubleOrNull != null -> element.double
            else -> element.content
        }
        is JsonArray -> element.map { jsonElementToAny(it) }
        is JsonObject -> element.toMap().mapValues { (_, v) -> jsonElementToAny(v) }
    }
}
