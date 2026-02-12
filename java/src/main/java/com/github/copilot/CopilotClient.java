/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.github.copilot.Types.*;
import com.github.copilot.internal.JsonRpcClient;

import java.io.*;
import java.net.Socket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Main client for interacting with the Copilot CLI.
 *
 * <p>The CopilotClient manages the connection to the Copilot CLI server and provides
 * methods to create and manage conversation sessions. It can either spawn a CLI
 * server process or connect to an existing server.
 *
 * <pre>{@code
 * // Create a client with default options (spawns CLI server)
 * CopilotClient client = new CopilotClient();
 *
 * // Or connect to an existing server
 * CopilotClient client = new CopilotClient(new CopilotClientOptions().cliUrl("localhost:3000"));
 *
 * // Create a session
 * CopilotSession session = client.createSession(new SessionConfig().model("gpt-4"));
 *
 * // Send messages and handle responses
 * session.on(event -> {
 *     if ("assistant.message".equals(event.type)) {
 *         System.out.println(event.data.get("content"));
 *     }
 * });
 * session.sendAndWait(new MessageOptions("Hello!"));
 *
 * // Clean up
 * session.destroy();
 * client.stop();
 * }</pre>
 */
public class CopilotClient {
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Pattern PORT_PATTERN = Pattern.compile("listening on port (\\d+)", Pattern.CASE_INSENSITIVE);

    private Process cliProcess;
    private JsonRpcClient rpcClient;
    private Socket tcpSocket;
    private int actualPort;
    private String actualHost = "localhost";
    private ConnectionState state = ConnectionState.DISCONNECTED;
    private final ConcurrentHashMap<String, CopilotSession> sessions = new ConcurrentHashMap<>();
    private final boolean isExternalServer;
    private boolean useStdio = true;
    private boolean autoStart = true;
    private boolean autoRestart = true;
    private volatile List<ModelInfo> modelsCache;
    private final Object modelsCacheLock = new Object();
    private final CopyOnWriteArrayList<SessionLifecycleHandler> lifecycleHandlers = new CopyOnWriteArrayList<>();
    private final ConcurrentHashMap<String, CopyOnWriteArrayList<SessionLifecycleHandler>> typedLifecycleHandlers = new ConcurrentHashMap<>();

    // Resolved options
    private String cliPath = "copilot";
    private String[] cliArgs = new String[0];
    private String cwd;
    private int port;
    private String logLevel = "info";
    private Map<String, String> env;
    private String githubToken;
    private boolean useLoggedInUser = true;

    /**
     * Creates a new CopilotClient with default options.
     */
    public CopilotClient() {
        this(null);
    }

    /**
     * Creates a new CopilotClient with the given options.
     *
     * @param options the client options
     */
    public CopilotClient(CopilotClientOptions options) {
        boolean external = false;

        if (options != null) {
            // Validate mutually exclusive options
            if (options.getCliUrl() != null && (options.getUseStdio() != null || options.getCliPath() != null)) {
                throw new IllegalArgumentException("cliUrl is mutually exclusive with useStdio and cliPath");
            }
            if (options.getCliUrl() != null && (options.getGithubToken() != null || options.getUseLoggedInUser() != null)) {
                throw new IllegalArgumentException("githubToken and useLoggedInUser cannot be used with cliUrl");
            }

            if (options.getCliUrl() != null) {
                int[] hostPort = parseCliUrl(options.getCliUrl());
                this.actualPort = hostPort[1];
                external = true;
                this.useStdio = false;
            }

            if (options.getCliPath() != null) this.cliPath = options.getCliPath();
            if (options.getCliArgs() != null) this.cliArgs = options.getCliArgs();
            if (options.getCwd() != null) this.cwd = options.getCwd();
            if (options.getPort() > 0) { this.port = options.getPort(); this.useStdio = false; }
            if (options.getLogLevel() != null) this.logLevel = options.getLogLevel();
            if (options.getUseStdio() != null) this.useStdio = options.getUseStdio();
            if (options.getAutoStart() != null) this.autoStart = options.getAutoStart();
            if (options.getAutoRestart() != null) this.autoRestart = options.getAutoRestart();
            if (options.getEnv() != null) this.env = options.getEnv();
            if (options.getGithubToken() != null) {
                this.githubToken = options.getGithubToken();
                this.useLoggedInUser = false;
            }
            if (options.getUseLoggedInUser() != null) this.useLoggedInUser = options.getUseLoggedInUser();
        }

        this.isExternalServer = external;

        // Check env for CLI path
        String envCliPath = System.getenv("COPILOT_CLI_PATH");
        if (envCliPath != null && !envCliPath.isEmpty()) {
            this.cliPath = envCliPath;
        }
    }

    private int[] parseCliUrl(String url) {
        String clean = url.replaceAll("^https?://", "");
        if (clean.matches("\\d+")) {
            int p = Integer.parseInt(clean);
            this.actualHost = "localhost";
            return new int[]{0, p};
        }
        String[] parts = clean.split(":");
        if (parts.length != 2) throw new IllegalArgumentException("Invalid cliUrl format: " + url);
        this.actualHost = parts[0].isEmpty() ? "localhost" : parts[0];
        int p = Integer.parseInt(parts[1]);
        if (p <= 0 || p > 65535) throw new IllegalArgumentException("Invalid port: " + url);
        return new int[]{0, p};
    }

    /**
     * Starts the CLI server and establishes a connection.
     */
    public void start() throws Exception {
        if (state == ConnectionState.CONNECTED) return;
        state = ConnectionState.CONNECTING;

        try {
            if (!isExternalServer) {
                startCLIServer();
            }
            connectToServer();
            verifyProtocolVersion();
            state = ConnectionState.CONNECTED;
        } catch (Exception e) {
            state = ConnectionState.ERROR;
            throw e;
        }
    }

    /**
     * Stops the CLI server and closes all active sessions.
     *
     * @return list of errors encountered during cleanup
     */
    public List<StopError> stop() {
        List<StopError> errors = new ArrayList<>();

        for (CopilotSession session : sessions.values()) {
            try {
                session.destroy();
            } catch (Exception e) {
                errors.add(new StopError("Failed to destroy session " + session.getSessionId() + ": " + e.getMessage()));
            }
        }
        sessions.clear();

        if (rpcClient != null) {
            rpcClient.stop();
            rpcClient = null;
        }

        synchronized (modelsCacheLock) {
            modelsCache = null;
        }

        if (tcpSocket != null) {
            try { tcpSocket.close(); } catch (IOException e) {
                errors.add(new StopError("Failed to close socket: " + e.getMessage()));
            }
            tcpSocket = null;
        }

        if (cliProcess != null && !isExternalServer) {
            cliProcess.destroyForcibly();
            cliProcess = null;
        }

        state = ConnectionState.DISCONNECTED;
        if (!isExternalServer) actualPort = 0;
        return errors;
    }

    /** Forcefully stops the CLI server without graceful cleanup. */
    public void forceStop() {
        sessions.clear();
        if (rpcClient != null) { rpcClient.stop(); rpcClient = null; }
        synchronized (modelsCacheLock) { modelsCache = null; }
        if (tcpSocket != null) { try { tcpSocket.close(); } catch (IOException ignored) {} tcpSocket = null; }
        if (cliProcess != null && !isExternalServer) { cliProcess.destroyForcibly(); cliProcess = null; }
        state = ConnectionState.DISCONNECTED;
        if (!isExternalServer) actualPort = 0;
    }

    /**
     * Creates a new conversation session.
     */
    @SuppressWarnings("unchecked")
    public CopilotSession createSession(SessionConfig config) throws Exception {
        ensureConnected();
        if (config == null) config = new SessionConfig();

        Map<String, Object> payload = buildCreateSessionPayload(config);
        Map<String, Object> response = rpcClient.request("session.create", payload);

        String sessionId = (String) response.get("sessionId");
        String workspacePath = (String) response.get("workspacePath");
        CopilotSession session = new CopilotSession(sessionId, rpcClient, workspacePath);
        session.registerTools(config.getTools());
        if (config.getOnPermissionRequest() != null) session.registerPermissionHandler(config.getOnPermissionRequest());
        if (config.getOnUserInputRequest() != null) session.registerUserInputHandler(config.getOnUserInputRequest());
        if (config.getHooks() != null) session.registerHooks(config.getHooks());
        sessions.put(sessionId, session);
        return session;
    }

    /** Creates a session with default configuration. */
    public CopilotSession createSession() throws Exception {
        return createSession(null);
    }

    /**
     * Resumes an existing conversation session.
     */
    @SuppressWarnings("unchecked")
    public CopilotSession resumeSession(String sessionId, SessionConfig config) throws Exception {
        ensureConnected();
        if (config == null) config = new SessionConfig();

        Map<String, Object> payload = buildCreateSessionPayload(config);
        payload.put("sessionId", sessionId);
        Map<String, Object> response = rpcClient.request("session.resume", payload);

        String resumedId = (String) response.get("sessionId");
        String workspacePath = (String) response.get("workspacePath");
        CopilotSession session = new CopilotSession(resumedId, rpcClient, workspacePath);
        session.registerTools(config.getTools());
        if (config.getOnPermissionRequest() != null) session.registerPermissionHandler(config.getOnPermissionRequest());
        if (config.getOnUserInputRequest() != null) session.registerUserInputHandler(config.getOnUserInputRequest());
        if (config.getHooks() != null) session.registerHooks(config.getHooks());
        sessions.put(resumedId, session);
        return session;
    }

    public CopilotSession resumeSession(String sessionId) throws Exception {
        return resumeSession(sessionId, null);
    }

    /** Gets the current connection state. */
    public ConnectionState getState() { return state; }

    /** Pings the server. */
    public PingResponse ping(String message) throws Exception {
        if (rpcClient == null) throw new IllegalStateException("Client not connected");
        Map<String, Object> result = rpcClient.request("ping", Map.of("message", message != null ? message : ""));
        PingResponse resp = new PingResponse();
        resp.message = (String) result.get("message");
        resp.timestamp = ((Number) result.get("timestamp")).longValue();
        if (result.containsKey("protocolVersion")) {
            resp.protocolVersion = ((Number) result.get("protocolVersion")).intValue();
        }
        return resp;
    }

    /** Gets CLI status. */
    public GetStatusResponse getStatus() throws Exception {
        if (rpcClient == null) throw new IllegalStateException("Client not connected");
        Map<String, Object> result = rpcClient.request("status.get", Map.of());
        GetStatusResponse resp = new GetStatusResponse();
        resp.version = (String) result.get("version");
        resp.protocolVersion = ((Number) result.get("protocolVersion")).intValue();
        return resp;
    }

    /** Gets authentication status. */
    public GetAuthStatusResponse getAuthStatus() throws Exception {
        if (rpcClient == null) throw new IllegalStateException("Client not connected");
        Map<String, Object> result = rpcClient.request("auth.getStatus", Map.of());
        return MAPPER.convertValue(result, GetAuthStatusResponse.class);
    }

    /** Lists available models (cached). */
    @SuppressWarnings("unchecked")
    public List<ModelInfo> listModels() throws Exception {
        if (rpcClient == null) throw new IllegalStateException("Client not connected");
        synchronized (modelsCacheLock) {
            if (modelsCache != null) return new ArrayList<>(modelsCache);
            Map<String, Object> result = rpcClient.request("models.list", Map.of());
            List<Map<String, Object>> modelsData = (List<Map<String, Object>>) result.get("models");
            List<ModelInfo> models = new ArrayList<>();
            if (modelsData != null) {
                for (Map<String, Object> m : modelsData) {
                    models.add(MAPPER.convertValue(m, ModelInfo.class));
                }
            }
            modelsCache = models;
            return new ArrayList<>(models);
        }
    }

    /** Lists all sessions. */
    @SuppressWarnings("unchecked")
    public List<SessionMetadata> listSessions() throws Exception {
        if (rpcClient == null) throw new IllegalStateException("Client not connected");
        Map<String, Object> result = rpcClient.request("session.list", Map.of());
        List<Map<String, Object>> sessionsData = (List<Map<String, Object>>) result.get("sessions");
        List<SessionMetadata> list = new ArrayList<>();
        if (sessionsData != null) {
            for (Map<String, Object> s : sessionsData) {
                list.add(MAPPER.convertValue(s, SessionMetadata.class));
            }
        }
        return list;
    }

    /** Deletes a session. */
    public void deleteSession(String sessionId) throws Exception {
        if (rpcClient == null) throw new IllegalStateException("Client not connected");
        Map<String, Object> result = rpcClient.request("session.delete", Map.of("sessionId", sessionId));
        boolean success = Boolean.TRUE.equals(result.get("success"));
        if (!success) {
            throw new RuntimeException("Failed to delete session " + sessionId + ": " + result.getOrDefault("error", "Unknown error"));
        }
        sessions.remove(sessionId);
    }

    /** Gets foreground session ID (TUI mode). */
    public String getForegroundSessionId() throws Exception {
        ensureConnected();
        Map<String, Object> result = rpcClient.request("session.getForeground", Map.of());
        return (String) result.get("sessionId");
    }

    /** Sets foreground session (TUI mode). */
    public void setForegroundSessionId(String sessionId) throws Exception {
        ensureConnected();
        Map<String, Object> result = rpcClient.request("session.setForeground", Map.of("sessionId", sessionId));
        if (!Boolean.TRUE.equals(result.get("success"))) {
            throw new RuntimeException("Failed to set foreground session: " + result.getOrDefault("error", "Unknown"));
        }
    }

    /** Subscribes to all session lifecycle events. */
    public Runnable on(SessionLifecycleHandler handler) {
        lifecycleHandlers.add(handler);
        return () -> lifecycleHandlers.remove(handler);
    }

    /** Subscribes to a specific lifecycle event type. */
    public Runnable on(String eventType, SessionLifecycleHandler handler) {
        typedLifecycleHandlers.computeIfAbsent(eventType, k -> new CopyOnWriteArrayList<>()).add(handler);
        return () -> {
            CopyOnWriteArrayList<SessionLifecycleHandler> handlers = typedLifecycleHandlers.get(eventType);
            if (handlers != null) handlers.remove(handler);
        };
    }

    // --- Private methods ---

    private void ensureConnected() throws Exception {
        if (rpcClient != null) return;
        if (autoStart) { start(); return; }
        throw new IllegalStateException("Client not connected. Call start() first.");
    }

    private Map<String, Object> buildCreateSessionPayload(SessionConfig config) {
        Map<String, Object> payload = new HashMap<>();
        if (config.getModel() != null) payload.put("model", config.getModel());
        if (config.getSessionId() != null) payload.put("sessionId", config.getSessionId());
        if (config.getReasoningEffort() != null) payload.put("reasoningEffort", config.getReasoningEffort());
        if (config.getConfigDir() != null) payload.put("configDir", config.getConfigDir());
        if (config.getTools() != null) {
            List<Map<String, Object>> toolDefs = new ArrayList<>();
            for (Types.Tool tool : config.getTools()) {
                Map<String, Object> def = new HashMap<>();
                def.put("name", tool.name);
                if (tool.description != null) def.put("description", tool.description);
                if (tool.parameters != null) def.put("parameters", tool.parameters);
                toolDefs.add(def);
            }
            payload.put("tools", toolDefs);
        }
        if (config.getSystemMessage() != null) payload.put("systemMessage", config.getSystemMessage());
        if (config.getAvailableTools() != null) payload.put("availableTools", config.getAvailableTools());
        if (config.getExcludedTools() != null) payload.put("excludedTools", config.getExcludedTools());
        if (config.getProvider() != null) payload.put("provider", config.getProvider());
        if (config.getOnPermissionRequest() != null) payload.put("requestPermission", true);
        if (config.getOnUserInputRequest() != null) payload.put("requestUserInput", true);
        if (config.getHooks() != null && config.getHooks().hasAnyHook()) payload.put("hooks", true);
        if (config.getWorkingDirectory() != null) payload.put("workingDirectory", config.getWorkingDirectory());
        if (config.getStreaming() != null) payload.put("streaming", config.getStreaming());
        if (config.getMcpServers() != null) payload.put("mcpServers", config.getMcpServers());
        if (config.getCustomAgents() != null) payload.put("customAgents", config.getCustomAgents());
        if (config.getSkillDirectories() != null) payload.put("skillDirectories", config.getSkillDirectories());
        if (config.getDisabledSkills() != null) payload.put("disabledSkills", config.getDisabledSkills());
        if (config.getInfiniteSessions() != null) payload.put("infiniteSessions", config.getInfiniteSessions());
        return payload;
    }

    private void verifyProtocolVersion() throws Exception {
        int expected = SdkProtocolVersion.get();
        PingResponse ping = ping(null);
        if (ping.protocolVersion == null) {
            throw new RuntimeException("SDK protocol version mismatch: SDK expects version " + expected
                + ", but server does not report a protocol version.");
        }
        if (ping.protocolVersion != expected) {
            throw new RuntimeException("SDK protocol version mismatch: SDK expects version " + expected
                + ", but server reports version " + ping.protocolVersion + ".");
        }
    }

    private void startCLIServer() throws Exception {
        List<String> args = new ArrayList<>();

        // If cliPath is a .js file, run with node
        if (cliPath.endsWith(".js")) {
            args.add("node");
            args.add(cliPath);
        } else {
            args.add(cliPath);
        }

        // Add extra CLI args
        args.addAll(Arrays.asList(cliArgs));
        args.addAll(List.of("--headless", "--no-auto-update", "--log-level", logLevel));

        if (useStdio) {
            args.add("--stdio");
        } else if (port > 0) {
            args.add("--port");
            args.add(String.valueOf(port));
        }

        if (githubToken != null) {
            args.add("--auth-token-env");
            args.add("COPILOT_SDK_AUTH_TOKEN");
        }
        if (!useLoggedInUser) {
            args.add("--no-auto-login");
        }

        ProcessBuilder pb = new ProcessBuilder(args);
        if (cwd != null) pb.directory(new File(cwd));

        // Set environment
        Map<String, String> processEnv = pb.environment();
        if (env != null) {
            processEnv.clear();
            processEnv.putAll(env);
        }
        if (githubToken != null) {
            processEnv.put("COPILOT_SDK_AUTH_TOKEN", githubToken);
        }

        pb.redirectErrorStream(false);
        cliProcess = pb.start();

        // Consume stderr in background
        Thread stderrThread = new Thread(() -> {
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(cliProcess.getErrorStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    // Optionally forward: System.err.println("[CLI] " + line);
                }
            } catch (IOException ignored) {}
        }, "cli-stderr");
        stderrThread.setDaemon(true);
        stderrThread.start();

        if (!useStdio) {
            // TCP mode: read stdout to get port
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(cliProcess.getInputStream()))) {
                long deadline = System.currentTimeMillis() + 10_000;
                String line;
                while ((line = reader.readLine()) != null) {
                    Matcher m = PORT_PATTERN.matcher(line);
                    if (m.find()) {
                        actualPort = Integer.parseInt(m.group(1));
                        return;
                    }
                    if (System.currentTimeMillis() > deadline) {
                        throw new RuntimeException("Timeout waiting for CLI server to start");
                    }
                }
                throw new RuntimeException("CLI process exited before announcing port");
            }
        }
    }

    private void connectToServer() throws Exception {
        if (useStdio) {
            connectViaStdio();
        } else {
            connectViaTcp();
        }
    }

    private void connectViaStdio() {
        if (cliProcess == null) throw new IllegalStateException("CLI process not started");
        rpcClient = new JsonRpcClient(cliProcess.getInputStream(), cliProcess.getOutputStream());
        setupHandlers();
        rpcClient.start();
    }

    private void connectViaTcp() throws Exception {
        if (actualPort == 0) throw new IllegalStateException("Server port not available");
        tcpSocket = new Socket(actualHost, actualPort);
        rpcClient = new JsonRpcClient(tcpSocket.getInputStream(), tcpSocket.getOutputStream());
        setupHandlers();
        rpcClient.start();
    }

    @SuppressWarnings("unchecked")
    private void setupHandlers() {
        rpcClient.setNotificationHandler((method, params) -> {
            if ("session.event".equals(method)) {
                String sessionId = (String) params.get("sessionId");
                Map<String, Object> event = (Map<String, Object>) params.get("event");
                CopilotSession session = sessions.get(sessionId);
                if (session != null && event != null) {
                    session.dispatchEvent(event);
                }
            } else if ("session.lifecycle".equals(method)) {
                dispatchLifecycleEvent(params);
            }
        });

        rpcClient.setRequestHandler("tool.call", params -> handleToolCallRequest(params));
        rpcClient.setRequestHandler("permission.request", params -> handlePermissionRequest(params));
        rpcClient.setRequestHandler("userInput.request", params -> handleUserInputRequest(params));
        rpcClient.setRequestHandler("hooks.invoke", params -> handleHooksInvoke(params));
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> handleToolCallRequest(Map<String, Object> params) throws Exception {
        String sessionId = (String) params.get("sessionId");
        String toolCallId = (String) params.get("toolCallId");
        String toolName = (String) params.get("toolName");
        Object arguments = params.get("arguments");

        CopilotSession session = sessions.get(sessionId);
        if (session == null) throw new RuntimeException("Unknown session " + sessionId);

        Types.ToolHandler handler = session.getToolHandler(toolName);
        if (handler == null) {
            return Map.of("result", Map.of(
                "textResultForLlm", "Tool '" + toolName + "' is not supported by this client instance.",
                "resultType", "failure",
                "error", "tool '" + toolName + "' not supported",
                "toolTelemetry", Map.of()
            ));
        }

        try {
            ToolInvocation invocation = new ToolInvocation(sessionId, toolCallId, toolName, arguments);
            Object result = handler.handle(arguments, invocation);
            return Map.of("result", normalizeToolResult(result));
        } catch (Exception e) {
            return Map.of("result", Map.of(
                "textResultForLlm", "Invoking this tool produced an error. Detailed information is not available.",
                "resultType", "failure",
                "error", e.getMessage(),
                "toolTelemetry", Map.of()
            ));
        }
    }

    private Map<String, Object> handlePermissionRequest(Map<String, Object> params) throws Exception {
        String sessionId = (String) params.get("sessionId");
        CopilotSession session = sessions.get(sessionId);
        if (session == null) throw new RuntimeException("Unknown session " + sessionId);

        try {
            PermissionRequestResult result = session.handlePermissionRequest(params.get("permissionRequest"));
            return Map.of("result", Map.of("kind", result.kind));
        } catch (Exception e) {
            return Map.of("result", Map.of("kind", "denied-no-approval-rule-and-could-not-request-from-user"));
        }
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> handleUserInputRequest(Map<String, Object> params) throws Exception {
        String sessionId = (String) params.get("sessionId");
        CopilotSession session = sessions.get(sessionId);
        if (session == null) throw new RuntimeException("Unknown session " + sessionId);

        UserInputResponse result = session.handleUserInputRequest(params);
        return Map.of("answer", result.answer, "wasFreeform", result.wasFreeform);
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> handleHooksInvoke(Map<String, Object> params) throws Exception {
        String sessionId = (String) params.get("sessionId");
        String hookType = (String) params.get("hookType");
        Object input = params.get("input");

        CopilotSession session = sessions.get(sessionId);
        if (session == null) throw new RuntimeException("Unknown session " + sessionId);

        Map<String, Object> output = session.handleHooksInvoke(hookType, input);
        Map<String, Object> result = new HashMap<>();
        if (output != null) result.put("output", output);
        return result;
    }

    private Object normalizeToolResult(Object result) {
        if (result == null) {
            return Map.of("textResultForLlm", "Tool returned no result", "resultType", "failure",
                "error", "tool returned no result", "toolTelemetry", Map.of());
        }
        if (result instanceof Map) {
            Map<?, ?> map = (Map<?, ?>) result;
            if (map.containsKey("textResultForLlm")) return result;
        }
        String text = result instanceof String ? (String) result : result.toString();
        return Map.of("textResultForLlm", text, "resultType", "success", "toolTelemetry", Map.of());
    }

    private void dispatchLifecycleEvent(Map<String, Object> params) {
        SessionLifecycleEvent event = new SessionLifecycleEvent();
        event.type = (String) params.get("type");
        event.sessionId = (String) params.get("sessionId");

        // Typed handlers
        CopyOnWriteArrayList<SessionLifecycleHandler> typed = typedLifecycleHandlers.get(event.type);
        if (typed != null) {
            for (SessionLifecycleHandler h : typed) {
                try { h.handle(event); } catch (Exception ignored) {}
            }
        }
        // Wildcard handlers
        for (SessionLifecycleHandler h : lifecycleHandlers) {
            try { h.handle(event); } catch (Exception ignored) {}
        }
    }
}
