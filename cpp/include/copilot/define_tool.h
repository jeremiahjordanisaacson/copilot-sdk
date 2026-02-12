/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

#pragma once

#include <string>
#include <optional>

#include <nlohmann/json.hpp>

#include "copilot/types.h"

namespace copilot {

/// Helper to define a tool with a typed handler.
///
/// The handler receives a nlohmann::json args object and ToolInvocation context,
/// and returns a ToolResultObject. For convenience, you can return a string
/// result using the overload that wraps it into a ToolResultObject.
///
/// Example:
/// @code
///   auto tool = copilot::defineTool("get_weather",
///       "Get the weather for a city",
///       R"({"type":"object","properties":{"city":{"type":"string"}}})"_json,
///       [](const nlohmann::json& args, const copilot::ToolInvocation& inv)
///           -> copilot::ToolResultObject {
///           std::string city = args.value("city", "unknown");
///           return copilot::ToolResultObject{
///               .textResultForLlm = "Weather in " + city + ": 22C sunny",
///               .resultType = "success"
///           };
///       });
/// @endcode
inline Tool defineTool(
    const std::string& name,
    const std::string& description,
    const nlohmann::json& parameters,
    ToolHandler handler)
{
    return Tool{
        name,
        description,
        parameters,
        std::move(handler)
    };
}

/// Overload without parameters (for tools that take no arguments).
inline Tool defineTool(
    const std::string& name,
    const std::string& description,
    ToolHandler handler)
{
    return Tool{
        name,
        description,
        std::nullopt,
        std::move(handler)
    };
}

/// Helper to create a successful ToolResultObject from a string.
inline ToolResultObject toolSuccess(const std::string& text) {
    return ToolResultObject{
        text,       // textResultForLlm
        {},         // binaryResultsForLlm
        "success",  // resultType
        std::nullopt,
        std::nullopt,
        nlohmann::json::object()
    };
}

/// Helper to create a failed ToolResultObject.
inline ToolResultObject toolFailure(const std::string& userMessage, const std::string& internalError = "") {
    return ToolResultObject{
        userMessage,
        {},
        "failure",
        internalError.empty() ? std::nullopt : std::optional<std::string>(internalError),
        std::nullopt,
        nlohmann::json::object()
    };
}

/// Helper to create a ToolResultObject from a JSON value (auto-serialized to string).
inline ToolResultObject toolSuccessJson(const nlohmann::json& value) {
    return ToolResultObject{
        value.dump(),
        {},
        "success",
        std::nullopt,
        std::nullopt,
        nlohmann::json::object()
    };
}

} // namespace copilot
