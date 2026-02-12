// ----------------------------------------------------------------------------------------------------
//  Copyright (c) Microsoft Corporation. All rights reserved.
// ----------------------------------------------------------------------------------------------------

// Basic example demonstrating the Copilot Swift SDK.
//
// Prerequisites:
// - The Copilot CLI must be installed and available in PATH (or specify cliPath).
// - You must be authenticated (via `copilot auth login` or by providing a token).
//
// Run with:
//   swift run BasicExample

import CopilotSDK
import Foundation

// MARK: - Tool Parameters

struct LookupFactParams: Codable {
    let topic: String
}

// MARK: - Main

@main
struct BasicExample {
    static func main() async throws {
        print("Starting Copilot SDK Example\n")

        // Define a simple tool
        let facts: [String: String] = [
            "javascript": "JavaScript was created in 10 days by Brendan Eich in 1995.",
            "node": "Node.js lets you run JavaScript outside the browser using the V8 engine.",
            "swift": "Swift was introduced by Apple in 2014 as a modern replacement for Objective-C.",
        ]

        let lookupFactTool = defineTool(
            name: "lookup_fact",
            description: "Returns a fun fact about a given topic.",
            parametersType: LookupFactParams.self
        ) { (params: LookupFactParams, _) -> Any? in
            let topic = params.topic.lowercased()
            return facts[topic] ?? "No fact stored for \(params.topic)."
        }

        // Create the client. Will auto-start the CLI server.
        let client = CopilotClient(options: CopilotClientOptions(logLevel: "info"))

        // Create a session with the tool
        let session = try await client.createSession(
            SessionConfig(tools: [lookupFactTool])
        )
        print("Session created: \(session.sessionId)\n")

        // Subscribe to all events
        await session.on { event in
            print("Event [\(event.type)]: \(event.data)")
        }

        // Send a simple message and wait for the response
        print("Sending message...")
        let result1 = try await session.sendAndWait(
            MessageOptions(prompt: "Tell me what 2+2 is")
        )
        if let content = result1?.data["content"] as? String {
            print("Response: \(content)\n")
        }

        // Send another message that uses the tool
        print("Sending follow-up message...")
        let result2 = try await session.sendAndWait(
            MessageOptions(prompt: "Use lookup_fact to tell me about 'swift'")
        )
        if let content = result2?.data["content"] as? String {
            print("Response: \(content)\n")
        }

        // Get conversation history
        let messages = try await session.getMessages()
        print("Total events in session history: \(messages.count)\n")

        // Clean up
        try await session.destroy()
        let errors = await client.stop()
        if !errors.isEmpty {
            print("Cleanup errors: \(errors)")
        }

        print("Done!")
    }
}
