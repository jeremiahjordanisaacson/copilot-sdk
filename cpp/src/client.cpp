/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

#include "copilot/client.h"
#include "copilot/sdk_protocol_version.h"

#include <algorithm>
#include <cstdlib>
#include <sstream>
#include <stdexcept>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace copilot {

// ============================================================================
// Construction / Destruction
// ============================================================================

CopilotClient::CopilotClient(const CopilotClientOptions& options)
    : options_(options) {
    // Validate mutually exclusive options
    if (options.cliUrl && (options.useStdio || !options.cliPath.empty())) {
        // Only throw if cliPath was explicitly set to something non-default
        // and cliUrl is also set
        if (options.cliUrl) {
            // Parse the URL now
            // Supports: "host:port", "http://host:port", "port"
            std::string url = *options.cliUrl;
            // Remove protocol
            if (url.find("https://") == 0) url = url.substr(8);
            else if (url.find("http://") == 0) url = url.substr(7);

            isExternalServer_ = true;
            options_.useStdio = false;
        }
    }

    // Check environment variable for CLI path
    const char* envPath = std::getenv("COPILOT_CLI_PATH");
    if (envPath && options_.cliPath == "copilot") {
        options_.cliPath = envPath;
    }
}

CopilotClient::~CopilotClient() {
    try {
        forceStop();
    } catch (...) {
        // Suppress all exceptions in destructor
    }
}

// ============================================================================
// Start / Stop
// ============================================================================

void CopilotClient::start() {
    if (state_ == ConnectionState::Connected) return;

    state_ = ConnectionState::Connecting;

    try {
        if (!isExternalServer_) {
            startCLIServer();
        }
        connectToServer();
        verifyProtocolVersion();
        state_ = ConnectionState::Connected;
    } catch (...) {
        state_ = ConnectionState::Error;
        throw;
    }
}

std::vector<std::string> CopilotClient::stop() {
    std::vector<std::string> errors;

    // Destroy all active sessions
    std::vector<std::shared_ptr<CopilotSession>> sessionList;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        for (auto& [id, session] : sessions_) {
            sessionList.push_back(session);
        }
    }

    for (auto& session : sessionList) {
        try {
            session->destroy();
        } catch (const std::exception& e) {
            errors.push_back("Failed to destroy session " + session->sessionId + ": " + e.what());
        }
    }

    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        sessions_.clear();
    }

    // Stop JSON-RPC client
    if (rpcClient_) {
        rpcClient_->stop();
        rpcClient_.reset();
    }

    // Clear models cache
    {
        std::lock_guard<std::mutex> lock(modelsCacheMutex_);
        modelsCache_.reset();
    }

    // Kill CLI process (only if we spawned it)
    if (!isExternalServer_) {
#ifdef _WIN32
        if (processHandle_) {
            TerminateProcess(processHandle_, 0);
            CloseHandle(processHandle_);
            processHandle_ = nullptr;
        }
        if (stdinWrite_) { CloseHandle(stdinWrite_); stdinWrite_ = nullptr; }
        if (stdoutRead_) { CloseHandle(stdoutRead_); stdoutRead_ = nullptr; }
#else
        if (processPid_ > 0) {
            kill(processPid_, SIGTERM);
            int status;
            waitpid(processPid_, &status, 0);
            processPid_ = -1;
        }
        if (stdinWriteFd_ >= 0) { close(stdinWriteFd_); stdinWriteFd_ = -1; }
        if (stdoutReadFd_ >= 0) { close(stdoutReadFd_); stdoutReadFd_ = -1; }
#endif
    }

    state_ = ConnectionState::Disconnected;
    return errors;
}

void CopilotClient::forceStop() {
    // Clear sessions immediately
    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        sessions_.clear();
    }

    // Stop JSON-RPC client
    if (rpcClient_) {
        rpcClient_->stop();
        rpcClient_.reset();
    }

    // Clear models cache
    {
        std::lock_guard<std::mutex> lock(modelsCacheMutex_);
        modelsCache_.reset();
    }

    // Kill process
    if (!isExternalServer_) {
#ifdef _WIN32
        if (processHandle_) {
            TerminateProcess(processHandle_, 0);
            CloseHandle(processHandle_);
            processHandle_ = nullptr;
        }
        if (stdinWrite_) { CloseHandle(stdinWrite_); stdinWrite_ = nullptr; }
        if (stdoutRead_) { CloseHandle(stdoutRead_); stdoutRead_ = nullptr; }
#else
        if (processPid_ > 0) {
            kill(processPid_, SIGKILL);
            int status;
            waitpid(processPid_, &status, WNOHANG);
            processPid_ = -1;
        }
        if (stdinWriteFd_ >= 0) { close(stdinWriteFd_); stdinWriteFd_ = -1; }
        if (stdoutReadFd_ >= 0) { close(stdoutReadFd_); stdoutReadFd_ = -1; }
#endif
    }

    state_ = ConnectionState::Disconnected;
}

// ============================================================================
// Session Management
// ============================================================================

void CopilotClient::ensureConnected() {
    if (rpcClient_) return;
    if (options_.autoStart) {
        start();
    } else {
        throw std::runtime_error("Client not connected. Call start() first.");
    }
}

std::shared_ptr<CopilotSession> CopilotClient::createSession(const SessionConfig& config) {
    ensureConnected();

    auto params = buildCreateSessionParams(config);
    auto result = rpcClient_->request("session.create", params);

    std::string sid = result.value("sessionId", "");
    std::string wp = result.value("workspacePath", "");

    auto session = std::shared_ptr<CopilotSession>(
        new CopilotSession(sid, rpcClient_.get(), wp));

    session->registerTools(config.tools);
    if (config.onPermissionRequest) {
        session->registerPermissionHandler(config.onPermissionRequest);
    }
    if (config.onUserInputRequest) {
        session->registerUserInputHandler(config.onUserInputRequest);
    }
    if (config.hooks && config.hooks->hasAny()) {
        session->registerHooks(*config.hooks);
    }

    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        sessions_[sid] = session;
    }

    return session;
}

std::shared_ptr<CopilotSession> CopilotClient::resumeSession(
    const std::string& sessionId, const ResumeSessionConfig& config) {
    ensureConnected();

    auto params = buildResumeSessionParams(sessionId, config);
    auto result = rpcClient_->request("session.resume", params);

    std::string sid = result.value("sessionId", "");
    std::string wp = result.value("workspacePath", "");

    auto session = std::shared_ptr<CopilotSession>(
        new CopilotSession(sid, rpcClient_.get(), wp));

    session->registerTools(config.tools);
    if (config.onPermissionRequest) {
        session->registerPermissionHandler(config.onPermissionRequest);
    }
    if (config.onUserInputRequest) {
        session->registerUserInputHandler(config.onUserInputRequest);
    }
    if (config.hooks && config.hooks->hasAny()) {
        session->registerHooks(*config.hooks);
    }

    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        sessions_[sid] = session;
    }

    return session;
}

ConnectionState CopilotClient::getState() const {
    return state_;
}

// ============================================================================
// Ping / Status / Models
// ============================================================================

PingResponse CopilotClient::ping(const std::string& message) {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("ping", {{"message", message}});
    return result.get<PingResponse>();
}

GetStatusResponse CopilotClient::getStatus() {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("status.get", nlohmann::json::object());
    return result.get<GetStatusResponse>();
}

GetAuthStatusResponse CopilotClient::getAuthStatus() {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("auth.getStatus", nlohmann::json::object());
    return result.get<GetAuthStatusResponse>();
}

std::vector<ModelInfo> CopilotClient::listModels() {
    if (!rpcClient_) throw std::runtime_error("Client not connected");

    std::lock_guard<std::mutex> lock(modelsCacheMutex_);
    if (modelsCache_) {
        return *modelsCache_;
    }

    auto result = rpcClient_->request("models.list", nlohmann::json::object());
    std::vector<ModelInfo> models;
    if (result.contains("models")) {
        models = result["models"].get<std::vector<ModelInfo>>();
    }
    modelsCache_ = models;
    return models;
}

std::optional<std::string> CopilotClient::getLastSessionId() {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("session.getLastId", nlohmann::json::object());
    if (result.contains("sessionId") && !result["sessionId"].is_null()) {
        return result["sessionId"].get<std::string>();
    }
    return std::nullopt;
}

void CopilotClient::deleteSession(const std::string& sessionId) {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("session.delete", {{"sessionId", sessionId}});
    bool success = result.value("success", false);
    if (!success) {
        std::string error = result.value("error", "Unknown error");
        throw std::runtime_error("Failed to delete session " + sessionId + ": " + error);
    }
    std::lock_guard<std::mutex> lock(sessionsMutex_);
    sessions_.erase(sessionId);
}

std::vector<SessionMetadata> CopilotClient::listSessions() {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("session.list", nlohmann::json::object());
    std::vector<SessionMetadata> sessions;
    if (result.contains("sessions")) {
        sessions = result["sessions"].get<std::vector<SessionMetadata>>();
    }
    return sessions;
}

std::optional<std::string> CopilotClient::getForegroundSessionId() {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("session.getForeground", nlohmann::json::object());
    if (result.contains("sessionId") && !result["sessionId"].is_null()) {
        return result["sessionId"].get<std::string>();
    }
    return std::nullopt;
}

void CopilotClient::setForegroundSessionId(const std::string& sessionId) {
    if (!rpcClient_) throw std::runtime_error("Client not connected");
    auto result = rpcClient_->request("session.setForeground", {{"sessionId", sessionId}});
    bool success = result.value("success", false);
    if (!success) {
        std::string error = result.value("error", "Failed to set foreground session");
        throw std::runtime_error(error);
    }
}

// ============================================================================
// Lifecycle Event Subscriptions
// ============================================================================

std::function<void()> CopilotClient::onLifecycle(SessionLifecycleHandler handler) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    uint64_t id = nextLifecycleId_++;
    lifecycleHandlers_.push_back({id, "", std::move(handler)});
    return [this, id]() {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        lifecycleHandlers_.erase(
            std::remove_if(lifecycleHandlers_.begin(), lifecycleHandlers_.end(),
                [id](const LifecycleEntry& e) { return e.id == id; }),
            lifecycleHandlers_.end());
    };
}

std::function<void()> CopilotClient::onLifecycle(const std::string& eventType,
                                                   SessionLifecycleHandler handler) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    uint64_t id = nextLifecycleId_++;
    lifecycleHandlers_.push_back({id, eventType, std::move(handler)});
    return [this, id]() {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        lifecycleHandlers_.erase(
            std::remove_if(lifecycleHandlers_.begin(), lifecycleHandlers_.end(),
                [id](const LifecycleEntry& e) { return e.id == id; }),
            lifecycleHandlers_.end());
    };
}

// ============================================================================
// Protocol Version Verification
// ============================================================================

void CopilotClient::verifyProtocolVersion() {
    auto response = ping();
    if (!response.protocolVersion) {
        throw std::runtime_error(
            "SDK protocol version mismatch: SDK expects version " +
            std::to_string(SDK_PROTOCOL_VERSION) +
            ", but server does not report a protocol version. "
            "Please update your server to ensure compatibility.");
    }
    if (*response.protocolVersion != SDK_PROTOCOL_VERSION) {
        throw std::runtime_error(
            "SDK protocol version mismatch: SDK expects version " +
            std::to_string(SDK_PROTOCOL_VERSION) +
            ", but server reports version " +
            std::to_string(*response.protocolVersion) +
            ". Please update your SDK or server to ensure compatibility.");
    }
}

// ============================================================================
// Process Spawning
// ============================================================================

void CopilotClient::startCLIServer() {
    std::vector<std::string> args;

    // Prepend any custom CLI args
    args.insert(args.end(), options_.cliArgs.begin(), options_.cliArgs.end());

    args.push_back("--headless");
    args.push_back("--no-auto-update");
    args.push_back("--log-level");
    args.push_back(options_.logLevel);

    if (options_.useStdio) {
        args.push_back("--stdio");
    } else if (options_.port > 0) {
        args.push_back("--port");
        args.push_back(std::to_string(options_.port));
    }

    // Auth flags
    if (options_.githubToken) {
        args.push_back("--auth-token-env");
        args.push_back("COPILOT_SDK_AUTH_TOKEN");
    }
    bool useLoggedIn = options_.useLoggedInUser.value_or(!options_.githubToken.has_value());
    if (!useLoggedIn) {
        args.push_back("--no-auto-login");
    }

#ifdef _WIN32
    // Windows: CreateProcess with pipes
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = nullptr;

    HANDLE childStdinRead, childStdinWrite;
    HANDLE childStdoutRead, childStdoutWrite;
    HANDLE childStderrRead, childStderrWrite;

    if (!CreatePipe(&childStdinRead, &childStdinWrite, &sa, 0))
        throw std::runtime_error("Failed to create stdin pipe");
    SetHandleInformation(childStdinWrite, HANDLE_FLAG_INHERIT, 0);

    if (!CreatePipe(&childStdoutRead, &childStdoutWrite, &sa, 0))
        throw std::runtime_error("Failed to create stdout pipe");
    SetHandleInformation(childStdoutRead, HANDLE_FLAG_INHERIT, 0);

    if (!CreatePipe(&childStderrRead, &childStderrWrite, &sa, 0))
        throw std::runtime_error("Failed to create stderr pipe");
    SetHandleInformation(childStderrRead, HANDLE_FLAG_INHERIT, 0);

    // Build command line
    std::string cmdLine = "\"" + options_.cliPath + "\"";
    for (const auto& arg : args) {
        cmdLine += " \"" + arg + "\"";
    }

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.hStdInput = childStdinRead;
    si.hStdOutput = childStdoutWrite;
    si.hStdError = childStderrWrite;
    si.dwFlags |= STARTF_USESTDHANDLES;

    ZeroMemory(&pi, sizeof(pi));

    // Set environment with auth token if needed
    char* envBlock = nullptr;
    std::string envString;
    if (options_.githubToken) {
        // Build environment block by copying current env and adding the token
        // For simplicity, we just use the current environment and set the var
        // via _putenv_s before CreateProcess and restore after
        _putenv_s("COPILOT_SDK_AUTH_TOKEN", options_.githubToken->c_str());
    }

    BOOL success = CreateProcessA(
        nullptr,
        const_cast<char*>(cmdLine.c_str()),
        nullptr, nullptr,
        TRUE, // Inherit handles
        0,
        envBlock,
        options_.cwd.empty() ? nullptr : options_.cwd.c_str(),
        &si, &pi);

    // Close child-side handles
    CloseHandle(childStdinRead);
    CloseHandle(childStdoutWrite);
    CloseHandle(childStderrWrite);

    if (!success) {
        CloseHandle(childStdinWrite);
        CloseHandle(childStdoutRead);
        CloseHandle(childStderrRead);
        throw std::runtime_error("Failed to start CLI server: CreateProcess failed");
    }

    CloseHandle(pi.hThread);
    CloseHandle(childStderrRead); // We don't read stderr for now

    processHandle_ = pi.hProcess;
    stdinWrite_ = childStdinWrite;
    stdoutRead_ = childStdoutRead;

#else
    // POSIX: fork + exec with pipes
    int stdinPipe[2];
    int stdoutPipe[2];
    int stderrPipe[2];

    if (pipe(stdinPipe) < 0 || pipe(stdoutPipe) < 0 || pipe(stderrPipe) < 0) {
        throw std::runtime_error("Failed to create pipes");
    }

    pid_t pid = fork();
    if (pid < 0) {
        throw std::runtime_error("Failed to fork");
    }

    if (pid == 0) {
        // Child process
        close(stdinPipe[1]);   // Close write end of stdin
        close(stdoutPipe[0]);  // Close read end of stdout
        close(stderrPipe[0]);  // Close read end of stderr

        dup2(stdinPipe[0], STDIN_FILENO);
        dup2(stdoutPipe[1], STDOUT_FILENO);
        dup2(stderrPipe[1], STDERR_FILENO);

        close(stdinPipe[0]);
        close(stdoutPipe[1]);
        close(stderrPipe[1]);

        if (!options_.cwd.empty()) {
            if (chdir(options_.cwd.c_str()) != 0) {
                _exit(1);
            }
        }

        // Set auth token env var if needed
        if (options_.githubToken) {
            setenv("COPILOT_SDK_AUTH_TOKEN", options_.githubToken->c_str(), 1);
        }

        // Build argv
        std::vector<const char*> argv;
        argv.push_back(options_.cliPath.c_str());
        for (const auto& arg : args) {
            argv.push_back(arg.c_str());
        }
        argv.push_back(nullptr);

        execvp(argv[0], const_cast<char* const*>(argv.data()));
        // If exec fails
        _exit(1);
    }

    // Parent process
    close(stdinPipe[0]);   // Close read end of stdin
    close(stdoutPipe[1]);  // Close write end of stdout
    close(stderrPipe[0]);  // Close read end of stderr (don't read it)
    close(stderrPipe[1]);  // Close write end too

    processPid_ = pid;
    stdinWriteFd_ = stdinPipe[1];
    stdoutReadFd_ = stdoutPipe[0];

#endif
}

void CopilotClient::connectToServer() {
    int readFd, writeFd;

#ifdef _WIN32
    readFd = _open_osfhandle(reinterpret_cast<intptr_t>(stdoutRead_), 0);
    writeFd = _open_osfhandle(reinterpret_cast<intptr_t>(stdinWrite_), 0);
    if (readFd < 0 || writeFd < 0) {
        throw std::runtime_error("Failed to open file descriptors for pipes");
    }
#else
    readFd = stdoutReadFd_;
    writeFd = stdinWriteFd_;
#endif

    rpcClient_ = std::make_unique<JsonRpcClient>(readFd, writeFd);
    setupHandlers();
    rpcClient_->start();
}

// ============================================================================
// Handler Setup
// ============================================================================

void CopilotClient::setupHandlers() {
    // session.event - notification (no response expected)
    rpcClient_->setRequestHandler("session.event",
        [this](const nlohmann::json& params) -> std::pair<nlohmann::json, std::optional<JsonRpcError>> {
            handleSessionEvent(params);
            return {nullptr, std::nullopt};
        });

    // session.lifecycle - notification
    rpcClient_->setRequestHandler("session.lifecycle",
        [this](const nlohmann::json& params) -> std::pair<nlohmann::json, std::optional<JsonRpcError>> {
            handleSessionLifecycle(params);
            return {nullptr, std::nullopt};
        });

    // tool.call - request (needs response)
    rpcClient_->setRequestHandler("tool.call",
        [this](const nlohmann::json& params) { return handleToolCall(params); });

    // permission.request - request
    rpcClient_->setRequestHandler("permission.request",
        [this](const nlohmann::json& params) { return handlePermissionRequest(params); });

    // userInput.request - request
    rpcClient_->setRequestHandler("userInput.request",
        [this](const nlohmann::json& params) { return handleUserInputRequest(params); });

    // hooks.invoke - request
    rpcClient_->setRequestHandler("hooks.invoke",
        [this](const nlohmann::json& params) { return handleHooksInvoke(params); });
}

// ============================================================================
// Server Request Handlers
// ============================================================================

void CopilotClient::handleSessionEvent(const nlohmann::json& params) {
    if (!params.contains("sessionId") || !params.contains("event")) return;

    std::string sid = params["sessionId"].get<std::string>();
    SessionEvent event = params["event"].get<SessionEvent>();

    std::shared_ptr<CopilotSession> session;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        auto it = sessions_.find(sid);
        if (it != sessions_.end()) session = it->second;
    }

    if (session) {
        session->dispatchEvent(event);
    }
}

void CopilotClient::handleSessionLifecycle(const nlohmann::json& params) {
    if (!params.contains("type") || !params.contains("sessionId")) return;

    SessionLifecycleEvent event = params.get<SessionLifecycleEvent>();

    std::vector<LifecycleEntry> snapshot;
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        snapshot = lifecycleHandlers_;
    }

    for (const auto& entry : snapshot) {
        if (entry.eventType.empty() || entry.eventType == event.type) {
            try {
                entry.fn(event);
            } catch (...) {}
        }
    }
}

std::pair<nlohmann::json, std::optional<JsonRpcError>>
CopilotClient::handleToolCall(const nlohmann::json& params) {
    std::string sid = params.value("sessionId", "");
    std::string toolCallId = params.value("toolCallId", "");
    std::string toolName = params.value("toolName", "");

    if (sid.empty() || toolCallId.empty() || toolName.empty()) {
        return {nullptr, JsonRpcError{-32602, "Invalid tool call payload"}};
    }

    std::shared_ptr<CopilotSession> session;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        auto it = sessions_.find(sid);
        if (it != sessions_.end()) session = it->second;
    }

    if (!session) {
        return {nullptr, JsonRpcError{-32602, "Unknown session " + sid}};
    }

    auto handler = session->getToolHandler(toolName);
    if (!handler) {
        nlohmann::json result;
        result["result"] = buildUnsupportedToolResult(toolName);
        return {result, std::nullopt};
    }

    ToolInvocation invocation{sid, toolCallId, toolName,
                              params.contains("arguments") ? params["arguments"] : nlohmann::json::object()};

    auto toolResult = executeToolCall(handler, invocation);
    nlohmann::json response;
    response["result"] = toolResult;
    return {response, std::nullopt};
}

std::pair<nlohmann::json, std::optional<JsonRpcError>>
CopilotClient::handlePermissionRequest(const nlohmann::json& params) {
    std::string sid = params.value("sessionId", "");
    if (sid.empty() || !params.contains("permissionRequest")) {
        return {nullptr, JsonRpcError{-32602, "Invalid permission request payload"}};
    }

    std::shared_ptr<CopilotSession> session;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        auto it = sessions_.find(sid);
        if (it != sessions_.end()) session = it->second;
    }

    if (!session) {
        return {nullptr, JsonRpcError{-32602, "Session not found: " + sid}};
    }

    try {
        auto permReq = params["permissionRequest"].get<PermissionRequest>();
        auto result = session->handlePermissionRequest(permReq);
        nlohmann::json response;
        response["result"] = result;
        return {response, std::nullopt};
    } catch (...) {
        nlohmann::json response;
        response["result"] = PermissionRequestResult{
            "denied-no-approval-rule-and-could-not-request-from-user"};
        return {response, std::nullopt};
    }
}

std::pair<nlohmann::json, std::optional<JsonRpcError>>
CopilotClient::handleUserInputRequest(const nlohmann::json& params) {
    std::string sid = params.value("sessionId", "");
    std::string question = params.value("question", "");

    if (sid.empty() || question.empty()) {
        return {nullptr, JsonRpcError{-32602, "Invalid user input request payload"}};
    }

    std::shared_ptr<CopilotSession> session;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        auto it = sessions_.find(sid);
        if (it != sessions_.end()) session = it->second;
    }

    if (!session) {
        return {nullptr, JsonRpcError{-32602, "Session not found: " + sid}};
    }

    try {
        UserInputRequest req;
        req.question = question;
        if (params.contains("choices")) req.choices = params["choices"].get<std::vector<std::string>>();
        if (params.contains("allowFreeform")) req.allowFreeform = params["allowFreeform"].get<bool>();

        auto response = session->handleUserInputRequest(req);
        return {response, std::nullopt};
    } catch (const std::exception& e) {
        return {nullptr, JsonRpcError{-32603, e.what()}};
    }
}

std::pair<nlohmann::json, std::optional<JsonRpcError>>
CopilotClient::handleHooksInvoke(const nlohmann::json& params) {
    std::string sid = params.value("sessionId", "");
    std::string hookType = params.value("hookType", "");

    if (sid.empty() || hookType.empty()) {
        return {nullptr, JsonRpcError{-32602, "Invalid hooks invoke payload"}};
    }

    std::shared_ptr<CopilotSession> session;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        auto it = sessions_.find(sid);
        if (it != sessions_.end()) session = it->second;
    }

    if (!session) {
        return {nullptr, JsonRpcError{-32602, "Session not found: " + sid}};
    }

    nlohmann::json input = params.contains("input") ? params["input"] : nlohmann::json::object();
    auto output = session->handleHooksInvoke(hookType, input);

    nlohmann::json response;
    if (!output.is_null()) {
        response["output"] = output;
    }
    return {response, std::nullopt};
}

// ============================================================================
// Tool Execution
// ============================================================================

ToolResultObject CopilotClient::executeToolCall(ToolHandler handler,
                                                 const ToolInvocation& invocation) {
    try {
        return handler(invocation.arguments, invocation);
    } catch (const std::exception& e) {
        return buildFailedToolResult(e.what());
    } catch (...) {
        return buildFailedToolResult("Unknown tool error");
    }
}

ToolResultObject CopilotClient::buildFailedToolResult(const std::string& error) {
    ToolResultObject result;
    result.textResultForLlm = "Invoking this tool produced an error. Detailed information is not available.";
    result.resultType = "failure";
    result.error = error;
    result.toolTelemetry = nlohmann::json::object();
    return result;
}

ToolResultObject CopilotClient::buildUnsupportedToolResult(const std::string& toolName) {
    ToolResultObject result;
    result.textResultForLlm = "Tool '" + toolName + "' is not supported by this client instance.";
    result.resultType = "failure";
    result.error = "tool '" + toolName + "' not supported";
    result.toolTelemetry = nlohmann::json::object();
    return result;
}

// ============================================================================
// Request Parameter Building
// ============================================================================

nlohmann::json CopilotClient::buildToolsJson(const std::vector<Tool>& tools) {
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& tool : tools) {
        nlohmann::json t = {{"name", tool.name}};
        if (tool.description) t["description"] = *tool.description;
        if (tool.parameters) t["parameters"] = *tool.parameters;
        arr.push_back(t);
    }
    return arr;
}

nlohmann::json CopilotClient::buildCreateSessionParams(const SessionConfig& config) {
    nlohmann::json params = nlohmann::json::object();

    if (config.model) params["model"] = *config.model;
    if (config.sessionId) params["sessionId"] = *config.sessionId;
    if (config.reasoningEffort) params["reasoningEffort"] = *config.reasoningEffort;
    if (config.configDir) params["configDir"] = *config.configDir;
    if (!config.tools.empty()) params["tools"] = buildToolsJson(config.tools);
    if (config.systemMessage) params["systemMessage"] = *config.systemMessage;
    if (config.availableTools) params["availableTools"] = *config.availableTools;
    if (config.excludedTools) params["excludedTools"] = *config.excludedTools;
    if (config.provider) params["provider"] = *config.provider;
    if (config.onPermissionRequest) params["requestPermission"] = true;
    if (config.onUserInputRequest) params["requestUserInput"] = true;
    if (config.hooks && config.hooks->hasAny()) params["hooks"] = true;
    if (config.workingDirectory) params["workingDirectory"] = *config.workingDirectory;
    if (config.streaming) params["streaming"] = true;
    if (config.mcpServers) params["mcpServers"] = *config.mcpServers;
    if (config.customAgents) params["customAgents"] = *config.customAgents;
    if (config.skillDirectories) params["skillDirectories"] = *config.skillDirectories;
    if (config.disabledSkills) params["disabledSkills"] = *config.disabledSkills;
    if (config.infiniteSessions) params["infiniteSessions"] = *config.infiniteSessions;

    return params;
}

nlohmann::json CopilotClient::buildResumeSessionParams(const std::string& sessionId,
                                                         const ResumeSessionConfig& config) {
    nlohmann::json params = {{"sessionId", sessionId}};

    if (config.model) params["model"] = *config.model;
    if (config.reasoningEffort) params["reasoningEffort"] = *config.reasoningEffort;
    if (!config.tools.empty()) params["tools"] = buildToolsJson(config.tools);
    if (config.systemMessage) params["systemMessage"] = *config.systemMessage;
    if (config.availableTools) params["availableTools"] = *config.availableTools;
    if (config.excludedTools) params["excludedTools"] = *config.excludedTools;
    if (config.provider) params["provider"] = *config.provider;
    if (config.streaming) params["streaming"] = true;
    if (config.onPermissionRequest) params["requestPermission"] = true;
    if (config.onUserInputRequest) params["requestUserInput"] = true;
    if (config.hooks && config.hooks->hasAny()) params["hooks"] = true;
    if (config.workingDirectory) params["workingDirectory"] = *config.workingDirectory;
    if (config.configDir) params["configDir"] = *config.configDir;
    if (config.disableResume) params["disableResume"] = true;
    if (config.mcpServers) params["mcpServers"] = *config.mcpServers;
    if (config.customAgents) params["customAgents"] = *config.customAgents;
    if (config.skillDirectories) params["skillDirectories"] = *config.skillDirectories;
    if (config.disabledSkills) params["disabledSkills"] = *config.disabledSkills;
    if (config.infiniteSessions) params["infiniteSessions"] = *config.infiniteSessions;

    return params;
}

} // namespace copilot
