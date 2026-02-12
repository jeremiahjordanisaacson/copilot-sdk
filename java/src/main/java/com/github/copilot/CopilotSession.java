/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot;

import com.github.copilot.Types.*;
import com.github.copilot.internal.JsonRpcClient;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Represents a single conversation session with the Copilot CLI.
 *
 * <p>A session maintains conversation state, handles events, and manages tool execution.
 * Sessions are created via {@link CopilotClient#createSession} or resumed via
 * {@link CopilotClient#resumeSession}.
 *
 * <pre>{@code
 * CopilotSession session = client.createSession(new SessionConfig().model("gpt-4"));
 *
 * session.on(event -> {
 *     if ("assistant.message".equals(event.type)) {
 *         System.out.println(event.data.get("content"));
 *     }
 * });
 *
 * session.sendAndWait(new MessageOptions("Hello, world!"));
 * session.destroy();
 * }</pre>
 */
public class CopilotSession {
    private final String sessionId;
    private final JsonRpcClient client;
    private final String workspacePath;
    private final CopyOnWriteArrayList<SessionEventHandler> eventHandlers = new CopyOnWriteArrayList<>();
    private final ConcurrentHashMap<String, CopyOnWriteArrayList<SessionEventHandler>> typedEventHandlers = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, ToolHandler> toolHandlers = new ConcurrentHashMap<>();
    private volatile PermissionHandler permissionHandler;
    private volatile UserInputHandler userInputHandler;
    private volatile SessionHooks hooks;

    CopilotSession(String sessionId, JsonRpcClient client, String workspacePath) {
        this.sessionId = sessionId;
        this.client = client;
        this.workspacePath = workspacePath;
    }

    /** Gets the unique session identifier. */
    public String getSessionId() { return sessionId; }

    /** Gets the workspace path (for infinite sessions). */
    public String getWorkspacePath() { return workspacePath; }

    /**
     * Sends a message to this session.
     *
     * @param options the message options
     * @return the message ID
     */
    @SuppressWarnings("unchecked")
    public String send(MessageOptions options) throws Exception {
        Map<String, Object> params = new HashMap<>();
        params.put("sessionId", sessionId);
        params.put("prompt", options.getPrompt());
        if (options.getAttachments() != null) {
            params.put("attachments", options.getAttachments());
        }
        if (options.getMode() != null) {
            params.put("mode", options.getMode());
        }

        Map<String, Object> response = client.request("session.send", params);
        return (String) response.get("messageId");
    }

    /**
     * Sends a message and waits until the session becomes idle.
     *
     * @param options the message options
     * @return the final assistant message event, or null
     */
    public SessionEvent sendAndWait(MessageOptions options) throws Exception {
        return sendAndWait(options, 60_000);
    }

    /**
     * Sends a message and waits until the session becomes idle with a custom timeout.
     *
     * @param options the message options
     * @param timeoutMs timeout in milliseconds
     * @return the final assistant message event, or null
     */
    public SessionEvent sendAndWait(MessageOptions options, long timeoutMs) throws Exception {
        CountDownLatch latch = new CountDownLatch(1);
        AtomicReference<SessionEvent> lastAssistantMessage = new AtomicReference<>();
        AtomicReference<Exception> sessionError = new AtomicReference<>();

        Runnable unsubscribe = on(event -> {
            if ("assistant.message".equals(event.type)) {
                lastAssistantMessage.set(event);
            } else if ("session.idle".equals(event.type)) {
                latch.countDown();
            } else if ("session.error".equals(event.type)) {
                String msg = event.data != null ? String.valueOf(event.data.get("message")) : "Unknown error";
                sessionError.set(new RuntimeException(msg));
                latch.countDown();
            }
        });

        try {
            send(options);
            if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                throw new RuntimeException("Timeout after " + timeoutMs + "ms waiting for session.idle");
            }
            if (sessionError.get() != null) {
                throw sessionError.get();
            }
            return lastAssistantMessage.get();
        } finally {
            unsubscribe.run();
        }
    }

    /**
     * Subscribes to all events from this session.
     *
     * @param handler the event handler
     * @return a Runnable that unsubscribes the handler when called
     */
    public Runnable on(SessionEventHandler handler) {
        eventHandlers.add(handler);
        return () -> eventHandlers.remove(handler);
    }

    /**
     * Subscribes to a specific event type.
     *
     * @param eventType the event type (e.g., "assistant.message")
     * @param handler the event handler
     * @return a Runnable that unsubscribes the handler when called
     */
    public Runnable on(String eventType, SessionEventHandler handler) {
        typedEventHandlers.computeIfAbsent(eventType, k -> new CopyOnWriteArrayList<>()).add(handler);
        return () -> {
            CopyOnWriteArrayList<SessionEventHandler> handlers = typedEventHandlers.get(eventType);
            if (handlers != null) handlers.remove(handler);
        };
    }

    /**
     * Retrieves all events and messages from this session's history.
     */
    @SuppressWarnings("unchecked")
    public List<SessionEvent> getMessages() throws Exception {
        Map<String, Object> response = client.request("session.getMessages", Map.of("sessionId", sessionId));
        List<Map<String, Object>> events = (List<Map<String, Object>>) response.get("events");
        if (events == null) return List.of();

        List<SessionEvent> result = new ArrayList<>();
        for (Map<String, Object> eventMap : events) {
            SessionEvent event = new SessionEvent();
            event.type = (String) eventMap.get("type");
            event.data = eventMap;
            result.add(event);
        }
        return result;
    }

    /** Destroys this session and releases resources. */
    public void destroy() throws Exception {
        client.request("session.destroy", Map.of("sessionId", sessionId));
        eventHandlers.clear();
        typedEventHandlers.clear();
        toolHandlers.clear();
        permissionHandler = null;
    }

    /** Aborts the currently processing message. */
    public void abort() throws Exception {
        client.request("session.abort", Map.of("sessionId", sessionId));
    }

    // --- Internal methods ---

    void registerTools(List<Tool> tools) {
        toolHandlers.clear();
        if (tools != null) {
            for (Tool tool : tools) {
                toolHandlers.put(tool.name, tool.handler);
            }
        }
    }

    void registerPermissionHandler(PermissionHandler handler) {
        this.permissionHandler = handler;
    }

    void registerUserInputHandler(UserInputHandler handler) {
        this.userInputHandler = handler;
    }

    void registerHooks(SessionHooks hooks) {
        this.hooks = hooks;
    }

    ToolHandler getToolHandler(String name) {
        return toolHandlers.get(name);
    }

    void dispatchEvent(SessionEvent event) {
        // Typed handlers
        CopyOnWriteArrayList<SessionEventHandler> typed = typedEventHandlers.get(event.type);
        if (typed != null) {
            for (SessionEventHandler handler : typed) {
                try { handler.handle(event); } catch (Exception ignored) {}
            }
        }
        // Wildcard handlers
        for (SessionEventHandler handler : eventHandlers) {
            try { handler.handle(event); } catch (Exception ignored) {}
        }
    }

    @SuppressWarnings("unchecked")
    void dispatchEvent(Map<String, Object> eventMap) {
        SessionEvent event = new SessionEvent();
        event.type = (String) eventMap.get("type");
        event.data = (Map<String, Object>) eventMap.getOrDefault("data", Map.of());
        dispatchEvent(event);
    }

    PermissionRequestResult handlePermissionRequest(Object request) throws Exception {
        if (permissionHandler == null) {
            return new PermissionRequestResult("denied-no-approval-rule-and-could-not-request-from-user");
        }
        PermissionRequest req = new PermissionRequest();
        if (request instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> map = (Map<String, Object>) request;
            req.kind = (String) map.get("kind");
            req.toolCallId = (String) map.get("toolCallId");
        }
        return permissionHandler.handle(req, sessionId);
    }

    UserInputResponse handleUserInputRequest(Map<String, Object> params) throws Exception {
        if (userInputHandler == null) {
            throw new RuntimeException("User input requested but no handler registered");
        }
        UserInputRequest req = new UserInputRequest();
        req.question = (String) params.get("question");
        req.choices = params.containsKey("choices") ? (List<String>) params.get("choices") : null;
        req.allowFreeform = (Boolean) params.get("allowFreeform");
        return userInputHandler.handle(req, sessionId);
    }

    @SuppressWarnings("unchecked")
    Map<String, Object> handleHooksInvoke(String hookType, Object input) throws Exception {
        if (hooks == null) return null;
        SessionHooks.HookHandler handler = hooks.getHandler(hookType);
        if (handler == null) return null;
        Map<String, Object> inputMap = input instanceof Map ? (Map<String, Object>) input : Map.of();
        return handler.handle(inputMap, sessionId);
    }
}
