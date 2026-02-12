// ----------------------------------------------------------------------------------------------------
//  Copyright (c) Microsoft Corporation. All rights reserved.
// ----------------------------------------------------------------------------------------------------

import Foundation

// MARK: - JSON-RPC Error

/// A JSON-RPC 2.0 error.
public struct JsonRpcError: Error, Sendable {
    public let code: Int
    public let message: String
    public let data: [String: Any]?

    public init(code: Int, message: String, data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var localizedDescription: String {
        "JSON-RPC Error \(code): \(message)"
    }
}

// MARK: - Request Handler

/// A handler that processes an incoming JSON-RPC request from the server
/// and returns a result dictionary (or nil for notifications).
public typealias JsonRpcRequestHandler = @Sendable ([String: Any]) async throws -> [String: Any]?

// MARK: - Notification Handler

/// A handler for incoming JSON-RPC notifications from the server.
public typealias JsonRpcNotificationHandler = @Sendable (String, [String: Any]) async -> Void

// MARK: - JSON-RPC Client

/// A JSON-RPC 2.0 client that communicates over stdio (stdin/stdout pipes)
/// using Content-Length header framing (LSP-style).
///
/// This client handles:
/// - Sending requests (with ID) and waiting for responses
/// - Sending notifications (no ID, no response expected)
/// - Receiving notifications from the server
/// - Receiving requests from the server and sending back responses
public actor JsonRpcClient {
    // MARK: - State

    private var nextId: Int = 1
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestHandlers: [String: JsonRpcRequestHandler] = [:]
    private var notificationHandler: JsonRpcNotificationHandler?
    private var writeHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Init

    public init() {}

    // MARK: - Start / Stop

    /// Starts listening for messages from the given read handle and uses the write handle for output.
    public func start(
        readHandle: FileHandle,
        writeHandle: FileHandle,
        notificationHandler: @escaping JsonRpcNotificationHandler
    ) {
        self.writeHandle = writeHandle
        self.notificationHandler = notificationHandler
        self.isRunning = true

        let readTask = Task { [weak self] in
            await self?.readLoop(readHandle: readHandle)
        }
        self.readTask = readTask
    }

    /// Stops the client and cancels the read loop.
    public func stop() {
        isRunning = false
        readTask?.cancel()
        readTask = nil

        // Fail all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: JsonRpcError(code: -32000, message: "Client stopped"))
        }
        pendingRequests.removeAll()
    }

    // MARK: - Request Handler Registration

    /// Registers a handler for incoming requests from the server with the given method name.
    public func setRequestHandler(method: String, handler: @escaping JsonRpcRequestHandler) {
        requestHandlers[method] = handler
    }

    /// Removes the request handler for the given method.
    public func removeRequestHandler(method: String) {
        requestHandlers.removeValue(forKey: method)
    }

    // MARK: - Send Request

    /// Sends a JSON-RPC request and waits for the response.
    public func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestId = String(nextId)
        nextId += 1

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": params,
        ]

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            do {
                try sendMessage(message)
            } catch {
                pendingRequests.removeValue(forKey: requestId)
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Send Notification

    /// Sends a JSON-RPC notification (no response expected).
    public func sendNotification(method: String, params: [String: Any]) throws {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        try sendMessage(message)
    }

    // MARK: - Private: Message Sending

    private func sendMessage(_ message: [String: Any]) throws {
        guard let writeHandle = writeHandle else {
            throw JsonRpcError(code: -32000, message: "Client not connected")
        }

        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        let header = "Content-Length: \(data.count)\r\n\r\n"

        guard let headerData = header.data(using: .utf8) else {
            throw JsonRpcError(code: -32000, message: "Failed to encode header")
        }

        writeHandle.write(headerData)
        writeHandle.write(data)
    }

    // MARK: - Private: Send Response

    private func sendResponse(id: Any, result: [String: Any]?) {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
        ]
        if let result = result {
            message["result"] = result
        } else {
            message["result"] = [String: Any]()
        }
        try? sendMessage(message)
    }

    private func sendErrorResponse(id: Any, code: Int, message: String) {
        let errorMessage: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ] as [String: Any],
        ]
        try? sendMessage(errorMessage)
    }

    // MARK: - Private: Read Loop

    private func readLoop(readHandle: FileHandle) async {
        // We accumulate data in a buffer and parse Content-Length framed messages.
        var buffer = Data()

        while isRunning && !Task.isCancelled {
            // Read available data from the file handle.
            let chunk: Data
            do {
                chunk = try await readData(from: readHandle)
            } catch {
                if isRunning {
                    // Read error; stop.
                }
                break
            }

            if chunk.isEmpty {
                // EOF
                break
            }

            buffer.append(chunk)

            // Parse as many complete messages as possible from the buffer.
            while let (message, consumed) = parseMessage(from: buffer) {
                buffer = buffer.dropFirst(consumed) as Data
                await handleIncomingMessage(message)
            }
        }
    }

    /// Reads available data from a FileHandle. Uses a background thread to avoid blocking.
    private func readData(from handle: FileHandle) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }

    /// Parses a Content-Length framed message from the buffer.
    /// Returns the parsed JSON dictionary and the number of bytes consumed, or nil if incomplete.
    private func parseMessage(from buffer: Data) -> ([String: Any], Int)? {
        guard let bufferString = String(data: buffer, encoding: .utf8) else {
            return nil
        }

        // Find the header separator
        guard let separatorRange = bufferString.range(of: "\r\n\r\n") else {
            return nil
        }

        let headerPart = String(bufferString[bufferString.startIndex..<separatorRange.lowerBound])

        // Parse Content-Length
        var contentLength: Int?
        for line in headerPart.split(separator: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("content-length:") {
                let valueStr = trimmed.dropFirst("content-length:".count).trimmingCharacters(
                    in: .whitespaces)
                contentLength = Int(valueStr)
                break
            }
        }

        guard let length = contentLength else {
            return nil
        }

        // Calculate byte offset of body start
        let headerEndIndex = separatorRange.upperBound
        let headerBytes = bufferString[bufferString.startIndex..<headerEndIndex].utf8.count

        // Check if we have enough data for the body
        guard buffer.count >= headerBytes + length else {
            return nil
        }

        let bodyData = buffer[buffer.startIndex.advanced(by: headerBytes)..<buffer.startIndex
            .advanced(by: headerBytes + length)]

        guard
            let json = try? JSONSerialization.jsonObject(with: bodyData, options: [])
                as? [String: Any]
        else {
            // Skip malformed message
            return nil
        }

        return (json, headerBytes + length)
    }

    // MARK: - Private: Message Dispatch

    private func handleIncomingMessage(_ message: [String: Any]) async {
        let hasMethod = message["method"] is String
        let hasId = message["id"] != nil

        if hasMethod {
            // This is a request or notification from the server
            let method = message["method"] as! String
            let params = message["params"] as? [String: Any] ?? [:]

            if hasId {
                // Server request - needs a response
                await handleServerRequest(id: message["id"]!, method: method, params: params)
            } else {
                // Server notification
                await notificationHandler?(method, params)
            }
        } else if hasId {
            // This is a response to one of our requests
            handleResponse(message)
        }
    }

    private func handleResponse(_ message: [String: Any]) {
        let id: String
        if let intId = message["id"] as? Int {
            id = String(intId)
        } else if let strId = message["id"] as? String {
            id = strId
        } else {
            return
        }

        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }

        if let error = message["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -32000
            let msg = error["message"] as? String ?? "Unknown error"
            let data = error["data"] as? [String: Any]
            continuation.resume(throwing: JsonRpcError(code: code, message: msg, data: data))
        } else if let result = message["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            // Some responses have non-dict results (e.g. null). Return empty dict.
            continuation.resume(returning: [:])
        }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) async {
        guard let handler = requestHandlers[method] else {
            sendErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            return
        }

        do {
            let result = try await handler(params)
            sendResponse(id: id, result: result)
        } catch let error as JsonRpcError {
            sendErrorResponse(id: id, code: error.code, message: error.message)
        } catch {
            sendErrorResponse(id: id, code: -32603, message: error.localizedDescription)
        }
    }
}
