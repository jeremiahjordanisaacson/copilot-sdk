// ----------------------------------------------------------------------------------------------------
//  Copyright (c) Microsoft Corporation. All rights reserved.
// ----------------------------------------------------------------------------------------------------

import Foundation

/// Helper to define a tool with automatic JSON schema generation from a Codable parameters type.
///
/// Usage:
/// ```swift
/// struct GetWeatherParams: Codable {
///     let city: String
///     let unit: String
/// }
///
/// let tool = defineTool(
///     name: "get_weather",
///     description: "Get weather for a city",
///     parametersType: GetWeatherParams.self
/// ) { (params: GetWeatherParams, invocation) in
///     return "Weather in \(params.city): 22 degrees \(params.unit)"
/// }
/// ```
///
/// - Parameters:
///   - name: The tool name.
///   - description: A description of what the tool does.
///   - parametersType: The Codable type of the parameters.
///   - handler: The handler function that receives decoded parameters and a ToolInvocation.
/// - Returns: A `Tool` ready to be passed to a SessionConfig.
public func defineTool<T: Decodable>(
    name: String,
    description: String? = nil,
    parametersType: T.Type,
    handler: @escaping @Sendable (T, ToolInvocation) async throws -> Any?
) -> Tool {
    let schema = generateJsonSchema(for: T.self)

    return Tool(
        name: name,
        description: description,
        parameters: schema
    ) { rawArgs, invocation in
        // Decode the raw arguments into the typed parameters
        let params: T
        if let dict = rawArgs as? [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            params = try JSONDecoder().decode(T.self, from: data)
        } else if rawArgs == nil {
            // Try decoding from empty object
            let data = "{}".data(using: .utf8)!
            params = try JSONDecoder().decode(T.self, from: data)
        } else {
            throw CopilotError.invalidResponse(
                "Tool arguments are not a dictionary: \(String(describing: rawArgs))")
        }

        return try await handler(params, invocation)
    }
}

/// Helper to define a tool with no parameters.
///
/// Usage:
/// ```swift
/// let tool = defineTool(
///     name: "get_time",
///     description: "Get the current time"
/// ) { invocation in
///     return ISO8601DateFormatter().string(from: Date())
/// }
/// ```
public func defineTool(
    name: String,
    description: String? = nil,
    handler: @escaping @Sendable (ToolInvocation) async throws -> Any?
) -> Tool {
    return Tool(
        name: name,
        description: description,
        parameters: nil
    ) { _, invocation in
        return try await handler(invocation)
    }
}

/// Helper to define a tool with an explicit JSON schema for parameters.
///
/// Usage:
/// ```swift
/// let tool = defineTool(
///     name: "lookup",
///     description: "Look up a topic",
///     parameters: [
///         "type": "object",
///         "properties": [
///             "topic": ["type": "string", "description": "Topic to look up"]
///         ],
///         "required": ["topic"]
///     ]
/// ) { args, invocation in
///     let dict = args as? [String: Any] ?? [:]
///     let topic = dict["topic"] as? String ?? ""
///     return "Info about \(topic)"
/// }
/// ```
public func defineTool(
    name: String,
    description: String? = nil,
    parameters: [String: Any],
    handler: @escaping @Sendable (Any?, ToolInvocation) async throws -> Any?
) -> Tool {
    return Tool(
        name: name,
        description: description,
        parameters: parameters,
        handler: handler
    )
}

// MARK: - Simple JSON Schema Generator

/// Generates a basic JSON schema for a Codable type using Mirror reflection.
///
/// This produces a simple `{ "type": "object", "properties": { ... } }` schema.
/// For production use with complex types, consider generating schemas externally
/// or providing them explicitly.
func generateJsonSchema<T>(for type: T.Type) -> [String: Any] {
    // Create an instance using JSONDecoder to inspect the structure.
    // For a basic approach, we reflect on the type's properties.
    let mirror = Mirror(reflecting: createDefaultInstance(of: type))

    var properties: [String: Any] = [:]
    var required: [String] = []

    for child in mirror.children {
        guard let label = child.label else { continue }

        let valueType = Swift.type(of: child.value)
        let (jsonType, isOptional) = swiftTypeToJsonType(valueType)

        properties[label] = ["type": jsonType]
        if !isOptional {
            required.append(label)
        }
    }

    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
    ]
    if !required.isEmpty {
        schema["required"] = required
    }
    return schema
}

/// Attempts to create a default instance of a type for reflection purposes.
/// Falls back to decoding from an empty JSON object.
private func createDefaultInstance<T>(of type: T.Type) -> Any {
    if let decodable = type as? Decodable.Type {
        if let data = "{}".data(using: .utf8),
            let instance = try? JSONDecoder().decode(decodable, from: data)
        {
            return instance
        }
    }
    // Return a dummy struct with no children as fallback
    return ()
}

/// Maps a Swift type to a JSON Schema type string.
private func swiftTypeToJsonType(_ type: Any.Type) -> (String, Bool) {
    let typeName = String(describing: type)

    // Check for Optional
    if typeName.hasPrefix("Optional<") {
        let inner = String(typeName.dropFirst("Optional<".count).dropLast(1))
        let (jsonType, _) = swiftTypeNameToJsonType(inner)
        return (jsonType, true)
    }

    return (swiftTypeNameToJsonType(typeName).0, false)
}

private func swiftTypeNameToJsonType(_ name: String) -> (String, Bool) {
    switch name {
    case "String":
        return ("string", false)
    case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
        return ("integer", false)
    case "Float", "Double", "CGFloat":
        return ("number", false)
    case "Bool":
        return ("boolean", false)
    default:
        if name.hasPrefix("Array<") || name.hasPrefix("[") {
            return ("array", false)
        }
        if name.hasPrefix("Dictionary<") || name.hasPrefix("[String") {
            return ("object", false)
        }
        return ("object", false)
    }
}
