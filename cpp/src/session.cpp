/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

#include "copilot/session.h"

#include <stdexcept>

namespace copilot {

// ============================================================================
// Construction
// ============================================================================

CopilotSession::CopilotSession(const std::string& sessionId, JsonRpcClient* client,
                                const std::string& workspacePath)
    : sessionId(sessionId), client_(client), workspacePath_(workspacePath) {}

std::string CopilotSession::workspacePath() const {
    return workspacePath_;
}

// ============================================================================
// Send / SendAndWait
// ============================================================================

std::string CopilotSession::send(const MessageOptions& options) {
    nlohmann::json params = {
        {"sessionId", sessionId},
        {"prompt", options.prompt}
    };
    if (!options.attachments.empty()) {
        params["attachments"] = options.attachments;
    }
    if (options.mode) {
        params["mode"] = *options.mode;
    }
    if (options.responseFormat) {
        params["responseFormat"] = responseFormatToString(*options.responseFormat);
    }
    if (options.imageOptions) {
        params["imageOptions"] = *options.imageOptions;
    }

    auto result = client_->request("session.send", params);
    return result.value("messageId", "");
}

std::optional<SessionEvent> CopilotSession::sendAndWait(const MessageOptions& options, int timeoutMs) {
    std::mutex mtx;
    std::condition_variable cv;
    bool idle = false;
    bool errorOccurred = false;
    std::string errorMessage;
    std::optional<SessionEvent> lastAssistantMessage;

    // Register handler BEFORE sending to avoid race condition
    auto handlerId = on([&](const SessionEvent& event) {
        std::lock_guard<std::mutex> lock(mtx);
        if (event.type == "assistant.message") {
            lastAssistantMessage = event;
        } else if (event.type == "session.idle") {
            idle = true;
            cv.notify_one();
        } else if (event.type == "session.error") {
            errorOccurred = true;
            if (event.data.contains("message")) {
                errorMessage = event.data["message"].get<std::string>();
            } else {
                errorMessage = "session error";
            }
            cv.notify_one();
        }
    });

    try {
        send(options);

        std::unique_lock<std::mutex> lock(mtx);
        bool completed = cv.wait_for(lock, std::chrono::milliseconds(timeoutMs), [&] {
            return idle || errorOccurred;
        });

        off(handlerId);

        if (!completed) {
            throw std::runtime_error("Timeout after " + std::to_string(timeoutMs) +
                                     "ms waiting for session.idle");
        }

        if (errorOccurred) {
            throw std::runtime_error("Session error: " + errorMessage);
        }

        return lastAssistantMessage;
    } catch (...) {
        off(handlerId);
        throw;
    }
}

// ============================================================================
// Event Subscriptions
// ============================================================================

uint64_t CopilotSession::on(SessionEventHandler handler) {
    std::lock_guard<std::mutex> lock(handlerMutex_);
    uint64_t id = nextHandlerId_++;
    handlers_.push_back({id, "", std::move(handler)});
    return id;
}

uint64_t CopilotSession::on(const std::string& eventType, SessionEventHandler handler) {
    std::lock_guard<std::mutex> lock(handlerMutex_);
    uint64_t id = nextHandlerId_++;
    handlers_.push_back({id, eventType, std::move(handler)});
    return id;
}

void CopilotSession::off(uint64_t handlerId) {
    std::lock_guard<std::mutex> lock(handlerMutex_);
    handlers_.erase(
        std::remove_if(handlers_.begin(), handlers_.end(),
            [handlerId](const HandlerEntry& e) { return e.id == handlerId; }),
        handlers_.end());
}

void CopilotSession::dispatchEvent(const SessionEvent& event) {
    // Take a snapshot of handlers under lock
    std::vector<HandlerEntry> snapshot;
    {
        std::lock_guard<std::mutex> lock(handlerMutex_);
        snapshot = handlers_;
    }

    for (const auto& entry : snapshot) {
        if (entry.eventType.empty() || entry.eventType == event.type) {
            try {
                entry.fn(event);
            } catch (...) {
                // Ignore handler errors
            }
        }
    }
}

// ============================================================================
// Tool Registration
// ============================================================================

void CopilotSession::registerTools(const std::vector<Tool>& tools) {
    std::lock_guard<std::mutex> lock(toolMutex_);
    toolHandlers_.clear();
    for (const auto& tool : tools) {
        if (!tool.name.empty() && tool.handler) {
            toolHandlers_[tool.name] = tool.handler;
        }
    }
}

ToolHandler CopilotSession::getToolHandler(const std::string& name) const {
    std::lock_guard<std::mutex> lock(toolMutex_);
    auto it = toolHandlers_.find(name);
    if (it != toolHandlers_.end()) return it->second;
    return nullptr;
}

// ============================================================================
// Permission Handling
// ============================================================================

void CopilotSession::registerPermissionHandler(PermissionHandler handler) {
    std::lock_guard<std::mutex> lock(permissionMutex_);
    permissionHandler_ = std::move(handler);
}

PermissionRequestResult CopilotSession::handlePermissionRequest(const PermissionRequest& request) {
    PermissionHandler handler;
    {
        std::lock_guard<std::mutex> lock(permissionMutex_);
        handler = permissionHandler_;
    }

    if (!handler) {
        return {"denied-no-approval-rule-and-could-not-request-from-user"};
    }

    try {
        return handler(request, sessionId);
    } catch (...) {
        return {"denied-no-approval-rule-and-could-not-request-from-user"};
    }
}

// ============================================================================
// User Input Handling
// ============================================================================

void CopilotSession::registerUserInputHandler(UserInputHandler handler) {
    std::lock_guard<std::mutex> lock(userInputMutex_);
    userInputHandler_ = std::move(handler);
}

UserInputResponse CopilotSession::handleUserInputRequest(const UserInputRequest& request) {
    UserInputHandler handler;
    {
        std::lock_guard<std::mutex> lock(userInputMutex_);
        handler = userInputHandler_;
    }

    if (!handler) {
        throw std::runtime_error("User input requested but no handler registered");
    }

    return handler(request, sessionId);
}

// ============================================================================
// Hooks Handling
// ============================================================================

void CopilotSession::registerHooks(const SessionHooks& hooks) {
    std::lock_guard<std::mutex> lock(hooksMutex_);
    hooks_ = hooks;
}

nlohmann::json CopilotSession::handleHooksInvoke(const std::string& hookType,
                                                  const nlohmann::json& input) {
    std::optional<SessionHooks> hooks;
    {
        std::lock_guard<std::mutex> lock(hooksMutex_);
        hooks = hooks_;
    }

    if (!hooks) return nullptr;

    try {
        if (hookType == "preToolUse" && hooks->onPreToolUse) {
            auto hookInput = input.get<PreToolUseHookInput>();
            auto result = hooks->onPreToolUse(hookInput, sessionId);
            if (result) return *result;
        } else if (hookType == "postToolUse" && hooks->onPostToolUse) {
            auto hookInput = input.get<PostToolUseHookInput>();
            auto result = hooks->onPostToolUse(hookInput, sessionId);
            if (result) return *result;
        } else if (hookType == "userPromptSubmitted" && hooks->onUserPromptSubmitted) {
            auto hookInput = input.get<UserPromptSubmittedHookInput>();
            auto result = hooks->onUserPromptSubmitted(hookInput, sessionId);
            if (result) return *result;
        } else if (hookType == "sessionStart" && hooks->onSessionStart) {
            auto hookInput = input.get<SessionStartHookInput>();
            auto result = hooks->onSessionStart(hookInput, sessionId);
            if (result) return *result;
        } else if (hookType == "sessionEnd" && hooks->onSessionEnd) {
            auto hookInput = input.get<SessionEndHookInput>();
            auto result = hooks->onSessionEnd(hookInput, sessionId);
            if (result) return *result;
        } else if (hookType == "errorOccurred" && hooks->onErrorOccurred) {
            auto hookInput = input.get<ErrorOccurredHookInput>();
            auto result = hooks->onErrorOccurred(hookInput, sessionId);
            if (result) return *result;
        }
    } catch (...) {
        // Hook handler error, return null
    }

    return nullptr;
}

// ============================================================================
// Messages / Destroy / Abort
// ============================================================================

std::vector<SessionEvent> CopilotSession::getMessages() {
    auto result = client_->request("session.getMessages", {{"sessionId", sessionId}});
    std::vector<SessionEvent> events;
    if (result.contains("events")) {
        for (const auto& e : result["events"]) {
            events.push_back(e.get<SessionEvent>());
        }
    }
    return events;
}

void CopilotSession::destroy() {
    client_->request("session.destroy", {{"sessionId", sessionId}});

    // Clear all handlers
    {
        std::lock_guard<std::mutex> lock(handlerMutex_);
        handlers_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(toolMutex_);
        toolHandlers_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(permissionMutex_);
        permissionHandler_ = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(userInputMutex_);
        userInputHandler_ = nullptr;
    }
}

void CopilotSession::abort() {
    client_->request("session.abort", {{"sessionId", sessionId}});
}

} // namespace copilot
