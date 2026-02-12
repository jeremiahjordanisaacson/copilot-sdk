// ----------------------------------------------------------------------------------------------------
//  Copyright (c) Microsoft Corporation. All rights reserved.
// ----------------------------------------------------------------------------------------------------

import Foundation

/// Main client for interacting with the Copilot CLI.
///
/// The `CopilotClient` manages the connection to the Copilot CLI server and provides
/// methods to create and manage conversation sessions. It can spawn a CLI server process
/// or connect to an existing server.
///
/// Example usage:
/// ```swift
/// let client = CopilotClient()
/// let session = try await client.createSession(SessionConfig(model: "gpt-4"))
///
/// session.on { event in
///     if event.type == "assistant.message" {
///         print(event.data["content"] as? String ?? "")
///     }
/// }
///
/// let response = try await session.sendAndWait(MessageOptions(prompt: "Hello!"))
/// try await session.destroy()
/// try await client.stop()
/// ```
public actor CopilotClient {
    // MARK: - Properties

    private let options: CopilotClientOptions
    private var state: ConnectionState = .disconnected
    private var cliProcess: Process?
    private var rpcClient: JsonRpcClient?
    private var sessions: [String: CopilotSession] = [:]
    private var isExternalServer: Bool = false
    private var modelsCache: [ModelInfo]?
    private var lifecycleHandlers: [UUID: SessionLifecycleHandler] = [:]

    // Resolved options
    private let resolvedCliPath: String
    private let resolvedUseStdio: Bool
    private let resolvedLogLevel: String
    private let resolvedAutoStart: Bool
    private let resolvedAutoRestart: Bool

    // MARK: - Init

    /// Creates a new CopilotClient instance.
    ///
    /// - Parameter options: Configuration options for the client.
    /// - Throws: If mutually exclusive options are provided.
    public init(options: CopilotClientOptions = CopilotClientOptions()) {
        // Validate options
        if options.cliUrl != nil && (options.useStdio == true || options.cliPath != nil) {
            fatalError("cliUrl is mutually exclusive with useStdio and cliPath")
        }
        if options.cliUrl != nil
            && (options.githubToken != nil || options.useLoggedInUser != nil)
        {
            fatalError(
                "githubToken and useLoggedInUser cannot be used with cliUrl (external server manages its own auth)"
            )
        }

        self.options = options
        self.isExternalServer = options.cliUrl != nil
        self.resolvedCliPath = options.cliPath ?? "copilot"
        self.resolvedUseStdio = options.cliUrl != nil ? false : (options.useStdio ?? true)
        self.resolvedLogLevel = options.logLevel ?? "info"
        self.resolvedAutoStart = options.autoStart ?? true
        self.resolvedAutoRestart = options.autoRestart ?? true
    }

    // MARK: - Connection State

    /// Gets the current connection state.
    public func getState() -> ConnectionState {
        return state
    }

    // MARK: - Start

    /// Starts the CLI server and establishes a connection.
    ///
    /// If connecting to an external server (via cliUrl), only establishes the connection.
    /// Otherwise, spawns the CLI server process and then connects.
    /// This method is called automatically when creating a session if `autoStart` is true.
    public func start() async throws {
        if state == .connected {
            return
        }

        state = .connecting

        do {
            if !isExternalServer {
                try await startCLIServer()
            }

            try await verifyProtocolVersion()
            state = .connected
        } catch {
            state = .error
            throw error
        }
    }

    // MARK: - Stop

    /// Stops the CLI server and closes all active sessions.
    ///
    /// - Returns: An array of errors encountered during cleanup.
    @discardableResult
    public func stop() async -> [Error] {
        var errors: [Error] = []

        // Destroy all sessions
        for (sessionId, session) in sessions {
            do {
                try await session.destroy()
            } catch {
                errors.append(
                    CopilotError.sessionCleanupFailed(
                        sessionId: sessionId, underlying: error))
            }
        }
        sessions.removeAll()

        // Stop RPC client
        if let rpc = rpcClient {
            await rpc.stop()
            rpcClient = nil
        }

        // Clear cache
        modelsCache = nil

        // Terminate CLI process
        if let process = cliProcess, !isExternalServer {
            process.terminate()
            cliProcess = nil
        }

        state = .disconnected
        return errors
    }

    /// Forcefully stops the CLI server without graceful cleanup.
    public func forceStop() async {
        sessions.removeAll()

        if let rpc = rpcClient {
            await rpc.stop()
            rpcClient = nil
        }

        modelsCache = nil

        if let process = cliProcess, !isExternalServer {
            process.terminate()
            cliProcess = nil
        }

        state = .disconnected
    }

    // MARK: - Create Session

    /// Creates a new conversation session with the Copilot CLI.
    ///
    /// - Parameter config: Configuration for the session.
    /// - Returns: The created session.
    public func createSession(_ config: SessionConfig = SessionConfig()) async throws
        -> CopilotSession
    {
        try await ensureConnected()

        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }

        var params: [String: Any] = [:]
        if let model = config.model { params["model"] = model }
        if let sid = config.sessionId { params["sessionId"] = sid }
        if let re = config.reasoningEffort { params["reasoningEffort"] = re.rawValue }
        if let tools = config.tools { params["tools"] = tools.map { $0.toWireFormat() } }
        if let sm = config.systemMessage {
            params["systemMessage"] = encodeToDictionary(sm)
        }
        if let at = config.availableTools { params["availableTools"] = at }
        if let et = config.excludedTools { params["excludedTools"] = et }
        if let provider = config.provider {
            params["provider"] = encodeToDictionary(provider)
        }
        params["requestPermission"] = config.onPermissionRequest != nil
        params["requestUserInput"] = config.onUserInputRequest != nil
        params["hooks"] = config.hooks?.hasAnyHandler ?? false
        if let wd = config.workingDirectory { params["workingDirectory"] = wd }
        if let streaming = config.streaming { params["streaming"] = streaming }
        if let mcp = config.mcpServers {
            params["mcpServers"] = mcp.mapValues { encodeToDictionary($0) ?? [:] }
        }
        if let agents = config.customAgents {
            params["customAgents"] = agents.map { encodeToDictionary($0) ?? [:] }
        }
        if let cd = config.configDir { params["configDir"] = cd }
        if let sd = config.skillDirectories { params["skillDirectories"] = sd }
        if let ds = config.disabledSkills { params["disabledSkills"] = ds }
        if let inf = config.infiniteSessions {
            params["infiniteSessions"] = encodeToDictionary(inf)
        }

        let response = try await rpc.sendRequest(method: "session.create", params: params)

        guard let sessionId = response["sessionId"] as? String else {
            throw CopilotError.invalidResponse("Missing sessionId in session.create response")
        }
        let workspacePath = response["workspacePath"] as? String

        let session = CopilotSession(
            sessionId: sessionId,
            rpcClient: rpc,
            workspacePath: workspacePath
        )

        if let tools = config.tools {
            await session.registerTools(tools)
        }
        if let handler = config.onPermissionRequest {
            await session.registerPermissionHandler(handler)
        }
        if let handler = config.onUserInputRequest {
            await session.registerUserInputHandler(handler)
        }
        if let hooks = config.hooks {
            await session.registerHooks(hooks)
        }

        sessions[sessionId] = session
        return session
    }

    // MARK: - Resume Session

    /// Resumes an existing conversation session by its ID.
    ///
    /// - Parameters:
    ///   - sessionId: The ID of the session to resume.
    ///   - config: Optional configuration for the resumed session.
    /// - Returns: The resumed session.
    public func resumeSession(_ sessionId: String, config: ResumeSessionConfig = ResumeSessionConfig()) async throws -> CopilotSession {
        try await ensureConnected()

        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }

        var params: [String: Any] = ["sessionId": sessionId]
        if let model = config.model { params["model"] = model }
        if let re = config.reasoningEffort { params["reasoningEffort"] = re.rawValue }
        if let tools = config.tools { params["tools"] = tools.map { $0.toWireFormat() } }
        if let sm = config.systemMessage {
            params["systemMessage"] = encodeToDictionary(sm)
        }
        if let at = config.availableTools { params["availableTools"] = at }
        if let et = config.excludedTools { params["excludedTools"] = et }
        if let provider = config.provider {
            params["provider"] = encodeToDictionary(provider)
        }
        params["requestPermission"] = config.onPermissionRequest != nil
        params["requestUserInput"] = config.onUserInputRequest != nil
        params["hooks"] = config.hooks?.hasAnyHandler ?? false
        if let wd = config.workingDirectory { params["workingDirectory"] = wd }
        if let cd = config.configDir { params["configDir"] = cd }
        if let streaming = config.streaming { params["streaming"] = streaming }
        if let mcp = config.mcpServers {
            params["mcpServers"] = mcp.mapValues { encodeToDictionary($0) ?? [:] }
        }
        if let agents = config.customAgents {
            params["customAgents"] = agents.map { encodeToDictionary($0) ?? [:] }
        }
        if let sd = config.skillDirectories { params["skillDirectories"] = sd }
        if let ds = config.disabledSkills { params["disabledSkills"] = ds }
        if let inf = config.infiniteSessions {
            params["infiniteSessions"] = encodeToDictionary(inf)
        }
        if let dr = config.disableResume { params["disableResume"] = dr }

        let response = try await rpc.sendRequest(method: "session.resume", params: params)

        guard let resumedSessionId = response["sessionId"] as? String else {
            throw CopilotError.invalidResponse("Missing sessionId in session.resume response")
        }
        let workspacePath = response["workspacePath"] as? String

        let session = CopilotSession(
            sessionId: resumedSessionId,
            rpcClient: rpc,
            workspacePath: workspacePath
        )

        if let tools = config.tools {
            await session.registerTools(tools)
        }
        if let handler = config.onPermissionRequest {
            await session.registerPermissionHandler(handler)
        }
        if let handler = config.onUserInputRequest {
            await session.registerUserInputHandler(handler)
        }
        if let hooks = config.hooks {
            await session.registerHooks(hooks)
        }

        sessions[resumedSessionId] = session
        return session
    }

    // MARK: - Ping

    /// Sends a ping to the server and returns the response.
    public func ping(message: String? = nil) async throws -> PingResponse {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }

        var params: [String: Any] = [:]
        if let msg = message { params["message"] = msg }

        let result = try await rpc.sendRequest(method: "ping", params: params)

        guard let msg = result["message"] as? String,
            let ts = result["timestamp"] as? Int64
        else {
            throw CopilotError.invalidResponse("Invalid ping response")
        }

        return PingResponse(
            message: msg,
            timestamp: ts,
            protocolVersion: result["protocolVersion"] as? Int
        )
    }

    // MARK: - Status

    /// Gets CLI status including version and protocol information.
    public func getStatus() async throws -> GetStatusResponse {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }
        let result = try await rpc.sendRequest(method: "status.get", params: [:])
        let data = try JSONSerialization.data(withJSONObject: result, options: [])
        return try JSONDecoder().decode(GetStatusResponse.self, from: data)
    }

    /// Gets current authentication status.
    public func getAuthStatus() async throws -> GetAuthStatusResponse {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }
        let result = try await rpc.sendRequest(method: "auth.getStatus", params: [:])
        let data = try JSONSerialization.data(withJSONObject: result, options: [])
        return try JSONDecoder().decode(GetAuthStatusResponse.self, from: data)
    }

    // MARK: - List Models

    /// Lists available models with their metadata.
    /// Results are cached after the first successful call.
    public func listModels() async throws -> [ModelInfo] {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }

        if let cached = modelsCache {
            return cached
        }

        let result = try await rpc.sendRequest(method: "models.list", params: [:])

        guard let modelsArray = result["models"] as? [[String: Any]] else {
            throw CopilotError.invalidResponse("Invalid models.list response")
        }

        let data = try JSONSerialization.data(withJSONObject: modelsArray, options: [])
        let models = try JSONDecoder().decode([ModelInfo].self, from: data)
        modelsCache = models
        return models
    }

    // MARK: - Session Management

    /// Gets the ID of the most recently updated session.
    public func getLastSessionId() async throws -> String? {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }
        let result = try await rpc.sendRequest(method: "session.getLastId", params: [:])
        return result["sessionId"] as? String
    }

    /// Deletes a session and its data from disk.
    public func deleteSession(_ sessionId: String) async throws {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }
        let result = try await rpc.sendRequest(
            method: "session.delete", params: ["sessionId": sessionId])
        let success = result["success"] as? Bool ?? false
        if !success {
            let errorMsg = result["error"] as? String ?? "Unknown error"
            throw CopilotError.sessionDeleteFailed(sessionId: sessionId, message: errorMsg)
        }
        sessions.removeValue(forKey: sessionId)
    }

    /// Lists all available sessions known to the server.
    public func listSessions() async throws -> [SessionMetadata] {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }
        let result = try await rpc.sendRequest(method: "session.list", params: [:])
        guard let sessionsArray = result["sessions"] as? [[String: Any]] else {
            throw CopilotError.invalidResponse("Invalid session.list response")
        }
        return sessionsArray.compactMap { dict in
            guard let sid = dict["sessionId"] as? String,
                let st = dict["startTime"] as? String,
                let mt = dict["modifiedTime"] as? String
            else { return nil }
            return SessionMetadata(
                sessionId: sid,
                startTime: st,
                modifiedTime: mt,
                summary: dict["summary"] as? String,
                isRemote: dict["isRemote"] as? Bool ?? false
            )
        }
    }

    /// Gets the foreground session ID in TUI+server mode.
    public func getForegroundSessionId() async throws -> String? {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }
        let result = try await rpc.sendRequest(method: "session.getForeground", params: [:])
        return result["sessionId"] as? String
    }

    /// Sets the foreground session in TUI+server mode.
    public func setForegroundSessionId(_ sessionId: String) async throws {
        guard let rpc = rpcClient else {
            throw CopilotError.notConnected
        }
        let result = try await rpc.sendRequest(
            method: "session.setForeground", params: ["sessionId": sessionId])
        let success = result["success"] as? Bool ?? false
        if !success {
            let errorMsg = result["error"] as? String ?? "Failed to set foreground session"
            throw CopilotError.operationFailed(errorMsg)
        }
    }

    // MARK: - Lifecycle Event Subscription

    /// Subscribes to all session lifecycle events.
    /// - Returns: An ID that can be used to unsubscribe.
    @discardableResult
    public func onLifecycleEvent(_ handler: @escaping SessionLifecycleHandler) -> UUID {
        let id = UUID()
        lifecycleHandlers[id] = handler
        return id
    }

    /// Unsubscribes from lifecycle events.
    public func removeLifecycleHandler(_ id: UUID) {
        lifecycleHandlers.removeValue(forKey: id)
    }

    // MARK: - Private: CLI Server

    private func startCLIServer() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedCliPath)

        var args = options.cliArgs ?? []
        args += ["--headless", "--no-auto-update", "--log-level", resolvedLogLevel]

        if resolvedUseStdio {
            args.append("--stdio")
        } else if let port = options.port, port > 0 {
            args += ["--port", String(port)]
        }

        if let token = options.githubToken {
            args += ["--auth-token-env", "COPILOT_SDK_AUTH_TOKEN"]
            var env = options.env ?? ProcessInfo.processInfo.environment
            env["COPILOT_SDK_AUTH_TOKEN"] = token
            process.environment = env
        } else {
            process.environment = options.env
        }

        let useLoggedIn = options.useLoggedInUser ?? (options.githubToken == nil)
        if !useLoggedIn {
            args.append("--no-auto-login")
        }

        process.arguments = args

        if let cwd = options.cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Forward stderr to our stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let str = String(data: data, encoding: .utf8) {
                    for line in str.split(separator: "\n") {
                        FileHandle.standardError.write(
                            "[CLI subprocess] \(line)\n".data(using: .utf8)!)
                    }
                }
            }
        }

        try process.run()
        cliProcess = process

        // Set up JSON-RPC client over stdio
        let rpc = JsonRpcClient()
        rpcClient = rpc

        await rpc.start(
            readHandle: stdoutPipe.fileHandleForReading,
            writeHandle: stdinPipe.fileHandleForWriting,
            notificationHandler: { [weak self] method, params in
                guard let self = self else { return }
                await self.handleNotification(method: method, params: params)
            }
        )

        // Register request handlers
        await rpc.setRequestHandler(method: "tool.call") { [weak self] params in
            guard let self = self else {
                throw JsonRpcError(code: -32000, message: "Client deallocated")
            }
            return try await self.handleToolCall(params)
        }

        await rpc.setRequestHandler(method: "permission.request") { [weak self] params in
            guard let self = self else {
                throw JsonRpcError(code: -32000, message: "Client deallocated")
            }
            return try await self.handlePermissionRequest(params)
        }

        await rpc.setRequestHandler(method: "userInput.request") { [weak self] params in
            guard let self = self else {
                throw JsonRpcError(code: -32000, message: "Client deallocated")
            }
            return try await self.handleUserInputRequest(params)
        }

        await rpc.setRequestHandler(method: "hooks.invoke") { [weak self] params in
            guard let self = self else {
                throw JsonRpcError(code: -32000, message: "Client deallocated")
            }
            return try await self.handleHooksInvoke(params)
        }
    }

    private func verifyProtocolVersion() async throws {
        let pingResult = try await ping()
        let expectedVersion = SDK_PROTOCOL_VERSION

        guard let serverVersion = pingResult.protocolVersion else {
            throw CopilotError.protocolVersionMismatch(
                expected: expectedVersion,
                actual: nil,
                message:
                    "SDK expects version \(expectedVersion), but server does not report a protocol version. "
                    + "Please update your server to ensure compatibility."
            )
        }

        if serverVersion != expectedVersion {
            throw CopilotError.protocolVersionMismatch(
                expected: expectedVersion,
                actual: serverVersion,
                message:
                    "SDK expects version \(expectedVersion), but server reports version \(serverVersion). "
                    + "Please update your SDK or server to ensure compatibility."
            )
        }
    }

    private func ensureConnected() async throws {
        if rpcClient == nil {
            if resolvedAutoStart {
                try await start()
            } else {
                throw CopilotError.notConnected
            }
        }
    }

    // MARK: - Private: Notification Handling

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "session.event":
            handleSessionEventNotification(params)
        case "session.lifecycle":
            handleSessionLifecycleNotification(params)
        default:
            break
        }
    }

    private func handleSessionEventNotification(_ params: [String: Any]) {
        guard let sessionId = params["sessionId"] as? String,
            let eventDict = params["event"] as? [String: Any],
            let event = SessionEvent.from(dict: eventDict)
        else { return }

        if let session = sessions[sessionId] {
            Task {
                await session.dispatchEvent(event)
            }
        }
    }

    private func handleSessionLifecycleNotification(_ params: [String: Any]) {
        let data = try? JSONSerialization.data(withJSONObject: params, options: [])
        guard let data = data,
            let event = try? JSONDecoder().decode(SessionLifecycleEvent.self, from: data)
        else { return }

        for handler in lifecycleHandlers.values {
            handler(event)
        }
    }

    // MARK: - Private: Server Request Handlers

    private func handleToolCall(_ params: [String: Any]) async throws -> [String: Any]? {
        guard let sessionId = params["sessionId"] as? String,
            let toolCallId = params["toolCallId"] as? String,
            let toolName = params["toolName"] as? String
        else {
            throw JsonRpcError(code: -32602, message: "Invalid tool call payload")
        }

        guard let session = sessions[sessionId] else {
            throw JsonRpcError(code: -32000, message: "Unknown session \(sessionId)")
        }

        let handler = await session.getToolHandler(toolName)
        guard let handler = handler else {
            return [
                "result": [
                    "textResultForLlm":
                        "Tool '\(toolName)' is not supported by this client instance.",
                    "resultType": "failure",
                    "error": "tool '\(toolName)' not supported",
                ] as [String: Any]
            ]
        }

        let invocation = ToolInvocation(
            sessionId: sessionId,
            toolCallId: toolCallId,
            toolName: toolName,
            arguments: params["arguments"]
        )

        do {
            let rawResult = try await handler(params["arguments"], invocation)
            let resultObj = normalizeToolResult(rawResult)
            return ["result": encodeToDictionary(resultObj) ?? [:]]
        } catch {
            return [
                "result": [
                    "textResultForLlm":
                        "Invoking this tool produced an error. Detailed information is not available.",
                    "resultType": "failure",
                    "error": error.localizedDescription,
                    "toolTelemetry": [:],
                ] as [String: Any]
            ]
        }
    }

    private func handlePermissionRequest(_ params: [String: Any]) async throws -> [String: Any]? {
        guard let sessionId = params["sessionId"] as? String,
            let requestData = params["permissionRequest"] as? [String: Any]
        else {
            throw JsonRpcError(code: -32602, message: "Invalid permission request payload")
        }

        guard let session = sessions[sessionId] else {
            throw JsonRpcError(code: -32000, message: "Session not found: \(sessionId)")
        }

        do {
            let result = try await session.handlePermissionRequest(requestData)
            return ["result": encodeToDictionary(result) ?? [:]]
        } catch {
            return [
                "result": [
                    "kind": "denied-no-approval-rule-and-could-not-request-from-user"
                ] as [String: Any]
            ]
        }
    }

    private func handleUserInputRequest(_ params: [String: Any]) async throws -> [String: Any]? {
        guard let sessionId = params["sessionId"] as? String,
            let question = params["question"] as? String
        else {
            throw JsonRpcError(code: -32602, message: "Invalid user input request payload")
        }

        guard let session = sessions[sessionId] else {
            throw JsonRpcError(code: -32000, message: "Session not found: \(sessionId)")
        }

        let request = UserInputRequest(
            question: question,
            choices: params["choices"] as? [String],
            allowFreeform: params["allowFreeform"] as? Bool
        )

        let result = try await session.handleUserInputRequest(request)
        return ["answer": result.answer, "wasFreeform": result.wasFreeform]
    }

    private func handleHooksInvoke(_ params: [String: Any]) async throws -> [String: Any]? {
        guard let sessionId = params["sessionId"] as? String,
            let hookType = params["hookType"] as? String
        else {
            throw JsonRpcError(code: -32602, message: "Invalid hooks invoke payload")
        }

        guard let session = sessions[sessionId] else {
            throw JsonRpcError(code: -32000, message: "Session not found: \(sessionId)")
        }

        let output = try await session.handleHooksInvoke(hookType: hookType, input: params["input"])
        if let output = output {
            return ["output": output]
        }
        return ["output": [:] as [String: Any]]
    }

    // MARK: - Private: Tool Result Normalization

    private func normalizeToolResult(_ result: Any?) -> ToolResultObject {
        if result == nil {
            return ToolResultObject(
                textResultForLlm: "Tool returned no result",
                resultType: .failure,
                error: "tool returned no result"
            )
        }

        if let resultObj = result as? ToolResultObject {
            return resultObj
        }

        if let toolResult = result as? ToolResult {
            return toolResult.toResultObject()
        }

        if let str = result as? String {
            return ToolResultObject(textResultForLlm: str, resultType: .success)
        }

        // Try to JSON-serialize other types
        if let data = try? JSONSerialization.data(
            withJSONObject: result!, options: []),
            let str = String(data: data, encoding: .utf8)
        {
            return ToolResultObject(textResultForLlm: str, resultType: .success)
        }

        return ToolResultObject(
            textResultForLlm: String(describing: result!), resultType: .success)
    }
}

// MARK: - Codable Helpers

/// Encodes a Codable value to a dictionary.
func encodeToDictionary<T: Encodable>(_ value: T) -> [String: Any]? {
    guard let data = try? JSONEncoder().encode(value),
        let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        return nil
    }
    return dict
}

// MARK: - Errors

/// Errors specific to the Copilot SDK.
public enum CopilotError: Error, LocalizedError {
    case notConnected
    case invalidResponse(String)
    case protocolVersionMismatch(expected: Int, actual: Int?, message: String)
    case sessionCleanupFailed(sessionId: String, underlying: Error)
    case sessionDeleteFailed(sessionId: String, message: String)
    case operationFailed(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Client not connected. Call start() first."
        case .invalidResponse(let msg):
            return "Invalid response from server: \(msg)"
        case .protocolVersionMismatch(_, _, let msg):
            return "SDK protocol version mismatch: \(msg)"
        case .sessionCleanupFailed(let sid, let err):
            return "Failed to clean up session \(sid): \(err.localizedDescription)"
        case .sessionDeleteFailed(let sid, let msg):
            return "Failed to delete session \(sid): \(msg)"
        case .operationFailed(let msg):
            return "Operation failed: \(msg)"
        case .timeout(let msg):
            return "Timeout: \(msg)"
        }
    }
}
