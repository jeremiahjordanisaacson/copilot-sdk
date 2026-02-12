// ----------------------------------------------------------------------------------------------------
//  Copyright (c) Microsoft Corporation. All rights reserved.
// ----------------------------------------------------------------------------------------------------

import Foundation

/// Represents a single conversation session with the Copilot CLI.
///
/// A session maintains conversation state, handles events, and manages tool execution.
/// Sessions are created via `CopilotClient.createSession()` or resumed via
/// `CopilotClient.resumeSession()`.
///
/// Example:
/// ```swift
/// let session = try await client.createSession()
///
/// session.on { event in
///     if event.type == "assistant.message" {
///         print(event.data["content"] as? String ?? "")
///     }
/// }
///
/// let response = try await session.sendAndWait(MessageOptions(prompt: "Hello!"))
/// try await session.destroy()
/// ```
public actor CopilotSession {
    // MARK: - Properties

    /// The unique identifier for this session.
    public let sessionId: String

    /// Path to the session workspace directory when infinite sessions are enabled.
    public let workspacePath: String?

    private let rpcClient: JsonRpcClient
    private var eventHandlers: [UUID: SessionEventHandler] = [:]
    private var typedEventHandlers: [String: [UUID: SessionEventHandler]] = [:]
    private var toolHandlers: [String: ToolHandler] = [:]
    private var permissionHandler: PermissionHandler?
    private var userInputHandler: UserInputHandler?
    private var hooks: SessionHooks?

    // MARK: - Init

    /// Creates a new CopilotSession.
    /// - Parameters:
    ///   - sessionId: The unique session identifier.
    ///   - rpcClient: The JSON-RPC client for communication.
    ///   - workspacePath: Optional workspace path for infinite sessions.
    init(sessionId: String, rpcClient: JsonRpcClient, workspacePath: String? = nil) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        self.workspacePath = workspacePath
    }

    // MARK: - Send Message

    /// Sends a message to this session.
    ///
    /// - Parameter options: The message options including prompt and optional attachments.
    /// - Returns: The message ID of the sent message.
    @discardableResult
    public func send(_ options: MessageOptions) async throws -> String {
        var params: [String: Any] = [
            "sessionId": sessionId,
            "prompt": options.prompt,
        ]

        if let attachments = options.attachments {
            params["attachments"] = attachments.map { $0.toDict() }
        }
        if let mode = options.mode {
            params["mode"] = mode
        }

        let response = try await rpcClient.sendRequest(method: "session.send", params: params)
        guard let messageId = response["messageId"] as? String else {
            throw CopilotError.invalidResponse("Missing messageId in session.send response")
        }
        return messageId
    }

    /// Sends a message and waits until the session becomes idle.
    ///
    /// This is a convenience method that combines `send` with waiting for the
    /// `session.idle` event. Events are still delivered to handlers while waiting.
    ///
    /// - Parameters:
    ///   - options: The message options.
    ///   - timeout: Timeout in seconds. Defaults to 60 seconds.
    /// - Returns: The final assistant message event, or nil if none was received.
    public func sendAndWait(
        _ options: MessageOptions,
        timeout: TimeInterval = 60
    ) async throws -> SessionEvent? {
        // Use a continuation-based approach: register event handler, send message,
        // wait for session.idle or session.error.

        return try await withCheckedThrowingContinuation { continuation in
            var lastAssistantMessage: SessionEvent?
            var resumed = false
            let handlerId = UUID()

            // Set up a timeout task
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !resumed {
                    resumed = true
                    // Remove the handler
                    Task { await self.removeEventHandler(handlerId) }
                    continuation.resume(
                        throwing: CopilotError.timeout(
                            "Timeout after \(timeout)s waiting for session.idle"))
                }
            }

            // Register event handler BEFORE sending to avoid race conditions
            let handler: SessionEventHandler = { event in
                if event.type == "assistant.message" {
                    lastAssistantMessage = event
                } else if event.type == "session.idle" {
                    if !resumed {
                        resumed = true
                        timeoutTask.cancel()
                        Task { await self.removeEventHandler(handlerId) }
                        continuation.resume(returning: lastAssistantMessage)
                    }
                } else if event.type == "session.error" {
                    if !resumed {
                        resumed = true
                        timeoutTask.cancel()
                        Task { await self.removeEventHandler(handlerId) }
                        let msg = event.data["message"] as? String ?? "Unknown session error"
                        continuation.resume(throwing: CopilotError.operationFailed(msg))
                    }
                }
            }

            eventHandlers[handlerId] = handler

            // Now send the message
            Task {
                do {
                    try await self.send(options)
                } catch {
                    if !resumed {
                        resumed = true
                        timeoutTask.cancel()
                        await self.removeEventHandler(handlerId)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Event Subscription

    /// Subscribes to all events from this session.
    ///
    /// - Parameter handler: A callback function that receives all session events.
    /// - Returns: An ID that can be used to unsubscribe via `removeEventHandler`.
    @discardableResult
    public func on(_ handler: @escaping SessionEventHandler) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }

    /// Subscribes to a specific event type from this session.
    ///
    /// - Parameters:
    ///   - eventType: The event type string (e.g., "assistant.message", "session.idle").
    ///   - handler: A callback function that receives events of that type.
    /// - Returns: An ID that can be used to unsubscribe.
    @discardableResult
    public func on(_ eventType: String, handler: @escaping SessionEventHandler) -> UUID {
        let id = UUID()
        if typedEventHandlers[eventType] == nil {
            typedEventHandlers[eventType] = [:]
        }
        typedEventHandlers[eventType]![id] = handler
        return id
    }

    /// Removes an event handler by its ID.
    public func removeEventHandler(_ id: UUID) {
        eventHandlers.removeValue(forKey: id)
        for key in typedEventHandlers.keys {
            typedEventHandlers[key]?.removeValue(forKey: id)
        }
    }

    // MARK: - Event Dispatch (Internal)

    /// Dispatches an event to all registered handlers.
    func dispatchEvent(_ event: SessionEvent) {
        // Dispatch to typed handlers
        if let typed = typedEventHandlers[event.type] {
            for handler in typed.values {
                handler(event)
            }
        }

        // Dispatch to wildcard handlers
        for handler in eventHandlers.values {
            handler(event)
        }
    }

    // MARK: - Tool Registration (Internal)

    /// Registers tool handlers for this session.
    func registerTools(_ tools: [Tool]) {
        toolHandlers.removeAll()
        for tool in tools {
            toolHandlers[tool.name] = tool.handler
        }
    }

    /// Gets a tool handler by name.
    func getToolHandler(_ name: String) -> ToolHandler? {
        return toolHandlers[name]
    }

    // MARK: - Permission Handler (Internal)

    /// Registers a permission handler.
    func registerPermissionHandler(_ handler: @escaping PermissionHandler) {
        permissionHandler = handler
    }

    /// Handles a permission request from the server.
    func handlePermissionRequest(_ requestData: [String: Any]) async throws
        -> PermissionRequestResult
    {
        guard let handler = permissionHandler else {
            return .denied
        }

        let request = PermissionRequest(
            kind: requestData["kind"] as? String ?? "unknown",
            toolCallId: requestData["toolCallId"] as? String,
            rawData: requestData
        )

        do {
            return try await handler(request, sessionId)
        } catch {
            return .denied
        }
    }

    // MARK: - User Input Handler (Internal)

    /// Registers a user input handler.
    func registerUserInputHandler(_ handler: @escaping UserInputHandler) {
        userInputHandler = handler
    }

    /// Handles a user input request from the server.
    func handleUserInputRequest(_ request: UserInputRequest) async throws -> UserInputResponse {
        guard let handler = userInputHandler else {
            throw CopilotError.operationFailed(
                "User input requested but no handler registered")
        }
        return try await handler(request, sessionId)
    }

    // MARK: - Hooks (Internal)

    /// Registers hook handlers.
    func registerHooks(_ hooks: SessionHooks) {
        self.hooks = hooks
    }

    /// Handles a hook invocation from the server.
    func handleHooksInvoke(hookType: String, input: Any?) async throws -> Any? {
        guard let hooks = hooks else {
            return nil
        }

        switch hookType {
        case "preToolUse":
            guard let handler = hooks.onPreToolUse else { return nil }
            if let inputDict = input as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: inputDict, options: [])
                let hookInput = try JSONDecoder().decode(PreToolUseHookInput.self, from: data)
                let output = try await handler(hookInput, sessionId)
                if let output = output {
                    return encodeToDictionary(output)
                }
            }
            return nil

        case "postToolUse":
            guard let handler = hooks.onPostToolUse else { return nil }
            if let inputDict = input as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: inputDict, options: [])
                let hookInput = try JSONDecoder().decode(PostToolUseHookInput.self, from: data)
                let output = try await handler(hookInput, sessionId)
                if let output = output {
                    return encodeToDictionary(output)
                }
            }
            return nil

        case "userPromptSubmitted":
            guard let handler = hooks.onUserPromptSubmitted else { return nil }
            if let inputDict = input as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: inputDict, options: [])
                let hookInput = try JSONDecoder().decode(
                    UserPromptSubmittedHookInput.self, from: data)
                let output = try await handler(hookInput, sessionId)
                if let output = output {
                    return encodeToDictionary(output)
                }
            }
            return nil

        case "sessionStart":
            guard let handler = hooks.onSessionStart else { return nil }
            if let inputDict = input as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: inputDict, options: [])
                let hookInput = try JSONDecoder().decode(SessionStartHookInput.self, from: data)
                let output = try await handler(hookInput, sessionId)
                if let output = output {
                    return encodeToDictionary(output)
                }
            }
            return nil

        case "sessionEnd":
            guard let handler = hooks.onSessionEnd else { return nil }
            if let inputDict = input as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: inputDict, options: [])
                let hookInput = try JSONDecoder().decode(SessionEndHookInput.self, from: data)
                let output = try await handler(hookInput, sessionId)
                if let output = output {
                    return encodeToDictionary(output)
                }
            }
            return nil

        case "errorOccurred":
            guard let handler = hooks.onErrorOccurred else { return nil }
            if let inputDict = input as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: inputDict, options: [])
                let hookInput = try JSONDecoder().decode(ErrorOccurredHookInput.self, from: data)
                let output = try await handler(hookInput, sessionId)
                if let output = output {
                    return encodeToDictionary(output)
                }
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Get Messages

    /// Retrieves all events and messages from this session's history.
    ///
    /// - Returns: An array of all session events.
    public func getMessages() async throws -> [SessionEvent] {
        let response = try await rpcClient.sendRequest(
            method: "session.getMessages",
            params: ["sessionId": sessionId]
        )

        guard let events = response["events"] as? [[String: Any]] else {
            throw CopilotError.invalidResponse("Invalid getMessages response")
        }

        return events.compactMap { SessionEvent.from(dict: $0) }
    }

    // MARK: - Destroy

    /// Destroys this session and releases all associated resources.
    ///
    /// After calling this method, the session can no longer be used. All event
    /// handlers and tool handlers are cleared.
    public func destroy() async throws {
        let _ = try await rpcClient.sendRequest(
            method: "session.destroy",
            params: ["sessionId": sessionId]
        )
        eventHandlers.removeAll()
        typedEventHandlers.removeAll()
        toolHandlers.removeAll()
        permissionHandler = nil
        userInputHandler = nil
        hooks = nil
    }

    // MARK: - Abort

    /// Aborts the currently processing message in this session.
    ///
    /// The session remains valid and can continue to be used for new messages.
    public func abort() async throws {
        let _ = try await rpcClient.sendRequest(
            method: "session.abort",
            params: ["sessionId": sessionId]
        )
    }
}
