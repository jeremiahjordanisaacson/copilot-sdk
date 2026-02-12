/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

/// Basic example of using the Copilot C++ SDK.
///
/// This example demonstrates:
/// - Creating a CopilotClient
/// - Defining custom tools
/// - Creating a session with tools and event handling
/// - Sending messages and waiting for responses
/// - Handling permissions and user input
/// - Graceful cleanup

#include <iostream>
#include <string>

#include <copilot/client.h>
#include <copilot/define_tool.h>
#include <copilot/session.h>
#include <copilot/types.h>

int main() {
    try {
        // Create client with default options (spawns CLI server via stdio)
        copilot::CopilotClientOptions options;
        options.cliPath = "copilot";  // Uses PATH lookup; set to full path if needed
        options.logLevel = "info";

        copilot::CopilotClient client(options);

        // Start the client (connects to CLI server)
        std::cout << "Starting Copilot client..." << std::endl;
        client.start();
        std::cout << "Connected!" << std::endl;

        // Verify connectivity with ping
        auto pingResp = client.ping("hello from C++ SDK");
        std::cout << "Ping response: " << pingResp.message
                  << " (protocol v" << pingResp.protocolVersion.value_or(0) << ")"
                  << std::endl;

        // Define a custom tool
        auto weatherTool = copilot::defineTool(
            "get_weather",
            "Get current weather for a city",
            nlohmann::json::parse(R"({
                "type": "object",
                "properties": {
                    "city": {
                        "type": "string",
                        "description": "The city name"
                    },
                    "unit": {
                        "type": "string",
                        "enum": ["celsius", "fahrenheit"],
                        "description": "Temperature unit"
                    }
                },
                "required": ["city"]
            })"),
            [](const nlohmann::json& args, const copilot::ToolInvocation& inv)
                -> copilot::ToolResultObject {
                std::string city = args.value("city", "unknown");
                std::string unit = args.value("unit", "celsius");
                std::cout << "[Tool] get_weather called for " << city << std::endl;

                nlohmann::json result = {
                    {"city", city},
                    {"temperature", 22},
                    {"unit", unit},
                    {"condition", "sunny"}
                };
                return copilot::toolSuccessJson(result);
            });

        // Create session configuration
        copilot::SessionConfig config;
        config.tools = {weatherTool};

        // Optional: Set up permission handler (auto-approve all)
        config.onPermissionRequest = [](const copilot::PermissionRequest& req,
                                        const std::string& sessionId)
            -> copilot::PermissionRequestResult {
            std::cout << "[Permission] " << req.kind << " requested for session "
                      << sessionId << " -> approved" << std::endl;
            return {"approved"};
        };

        // Create a session
        std::cout << "\nCreating session..." << std::endl;
        auto session = client.createSession(config);
        std::cout << "Session created: " << session->sessionId << std::endl;

        // Subscribe to events
        auto handlerId = session->on([](const copilot::SessionEvent& event) {
            if (event.type == "assistant.message") {
                std::string content = event.data.value("content", "");
                std::cout << "\n--- Assistant ---\n" << content << "\n-----------------" << std::endl;
            } else if (event.type == "tool.execution_start") {
                std::string toolName = event.data.value("toolName", "");
                std::cout << "[Event] Tool execution started: " << toolName << std::endl;
            } else if (event.type == "tool.execution_complete") {
                bool success = event.data.value("success", false);
                std::cout << "[Event] Tool execution complete (success=" << success << ")" << std::endl;
            } else if (event.type == "session.idle") {
                std::cout << "[Event] Session idle" << std::endl;
            }
        });

        // Send a message and wait for the response
        std::cout << "\nSending message..." << std::endl;
        auto response = session->sendAndWait(
            copilot::MessageOptions{.prompt = "What is the weather in Tokyo?"},
            120000  // 2 minute timeout
        );

        if (response) {
            std::cout << "\nFinal response received." << std::endl;
        } else {
            std::cout << "\nNo assistant message received." << std::endl;
        }

        // Retrieve conversation history
        auto messages = session->getMessages();
        std::cout << "\nSession has " << messages.size() << " events in history." << std::endl;

        // Clean up
        std::cout << "\nCleaning up..." << std::endl;
        session->off(handlerId);
        session->destroy();

        auto errors = client.stop();
        if (errors.empty()) {
            std::cout << "Client stopped successfully." << std::endl;
        } else {
            std::cerr << "Client stopped with " << errors.size() << " error(s):" << std::endl;
            for (const auto& err : errors) {
                std::cerr << "  - " << err << std::endl;
            }
        }

    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }

    return 0;
}
