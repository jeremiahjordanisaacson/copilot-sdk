/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;
import java.util.Map;

/**
 * Type definitions for the Copilot SDK.
 */
public final class Types {
    private Types() {}

    /** Connection state of the client. */
    public enum ConnectionState {
        DISCONNECTED, CONNECTING, CONNECTED, ERROR
    }

    /** Result type from a tool execution. */
    public enum ToolResultType {
        @JsonProperty("success") SUCCESS,
        @JsonProperty("failure") FAILURE,
        @JsonProperty("rejected") REJECTED,
        @JsonProperty("denied") DENIED
    }

    /** Reasoning effort levels for models that support it. */
    public enum ReasoningEffort {
        @JsonProperty("low") LOW,
        @JsonProperty("medium") MEDIUM,
        @JsonProperty("high") HIGH,
        @JsonProperty("xhigh") XHIGH
    }

    /** Structured result from a tool execution. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ToolResultObject {
        @JsonProperty("textResultForLlm") public String textResultForLlm;
        @JsonProperty("resultType") public String resultType;
        @JsonProperty("error") public String error;
        @JsonProperty("sessionLog") public String sessionLog;
        @JsonProperty("toolTelemetry") public Map<String, Object> toolTelemetry;

        public ToolResultObject() {}

        public ToolResultObject(String textResultForLlm, String resultType, String error) {
            this.textResultForLlm = textResultForLlm;
            this.resultType = resultType;
            this.error = error;
            this.toolTelemetry = Map.of();
        }
    }

    /** Information about a tool invocation. */
    public static class ToolInvocation {
        public String sessionId;
        public String toolCallId;
        public String toolName;
        public Object arguments;

        public ToolInvocation(String sessionId, String toolCallId, String toolName, Object arguments) {
            this.sessionId = sessionId;
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.arguments = arguments;
        }
    }

    /** Tool definition for registering custom tools. */
    public static class Tool {
        public String name;
        public String description;
        public Map<String, Object> parameters;
        public ToolHandler handler;

        public Tool(String name, String description, Map<String, Object> parameters, ToolHandler handler) {
            this.name = name;
            this.description = description;
            this.parameters = parameters;
            this.handler = handler;
        }
    }

    /** Functional interface for tool handlers. */
    @FunctionalInterface
    public interface ToolHandler {
        Object handle(Object args, ToolInvocation invocation) throws Exception;
    }

    /** System message configuration - append mode. */
    public static class SystemMessageAppendConfig {
        public String mode = "append";
        public String content;
    }

    /** System message configuration - replace mode. */
    public static class SystemMessageReplaceConfig {
        public String mode = "replace";
        public String content;
    }

    /** Permission request from the server. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class PermissionRequest {
        public String kind;
        public String toolCallId;
    }

    /** Permission request result. */
    public static class PermissionRequestResult {
        public String kind;
        public List<Object> rules;

        public PermissionRequestResult() {}
        public PermissionRequestResult(String kind) { this.kind = kind; }
    }

    /** Functional interface for permission request handlers. */
    @FunctionalInterface
    public interface PermissionHandler {
        PermissionRequestResult handle(PermissionRequest request, String sessionId) throws Exception;
    }

    /** User input request from the agent. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class UserInputRequest {
        public String question;
        public List<String> choices;
        public Boolean allowFreeform;
    }

    /** User input response. */
    public static class UserInputResponse {
        public String answer;
        public boolean wasFreeform;

        public UserInputResponse(String answer, boolean wasFreeform) {
            this.answer = answer;
            this.wasFreeform = wasFreeform;
        }
    }

    /** Functional interface for user input handlers. */
    @FunctionalInterface
    public interface UserInputHandler {
        UserInputResponse handle(UserInputRequest request, String sessionId) throws Exception;
    }

    /** Provider configuration for BYOK. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ProviderConfig {
        public String type;
        @JsonProperty("baseUrl") public String baseUrl;
        @JsonProperty("apiKey") public String apiKey;
        @JsonProperty("bearerToken") public String bearerToken;
        @JsonProperty("wireApi") public String wireApi;
    }

    /** MCP server configuration. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class MCPServerConfig {
        public List<String> tools;
        public String type;
        public Integer timeout;
        public String command;
        public List<String> args;
        public Map<String, String> env;
        public String cwd;
        public String url;
        public Map<String, String> headers;
    }

    /** Custom agent configuration. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class CustomAgentConfig {
        public String name;
        @JsonProperty("displayName") public String displayName;
        public String description;
        public List<String> tools;
        public String prompt;
        @JsonProperty("mcpServers") public Map<String, MCPServerConfig> mcpServers;
        public Boolean infer;
    }

    /** Infinite session configuration. */
    public static class InfiniteSessionConfig {
        public Boolean enabled;
        @JsonProperty("backgroundCompactionThreshold") public Double backgroundCompactionThreshold;
        @JsonProperty("bufferExhaustionThreshold") public Double bufferExhaustionThreshold;
    }

    /** Ping response. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class PingResponse {
        public String message;
        public long timestamp;
        @JsonProperty("protocolVersion") public Integer protocolVersion;
    }

    /** Status response. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class GetStatusResponse {
        public String version;
        @JsonProperty("protocolVersion") public int protocolVersion;
    }

    /** Auth status response. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class GetAuthStatusResponse {
        @JsonProperty("isAuthenticated") public boolean isAuthenticated;
        @JsonProperty("authType") public String authType;
        public String host;
        public String login;
        @JsonProperty("statusMessage") public String statusMessage;
    }

    /** Model capabilities. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ModelCapabilities {
        public ModelSupports supports;
        public ModelLimits limits;

        @JsonIgnoreProperties(ignoreUnknown = true)
        public static class ModelSupports {
            public boolean vision;
            @JsonProperty("reasoningEffort") public boolean reasoningEffort;
        }

        @JsonIgnoreProperties(ignoreUnknown = true)
        public static class ModelLimits {
            @JsonProperty("max_prompt_tokens") public Integer maxPromptTokens;
            @JsonProperty("max_context_window_tokens") public int maxContextWindowTokens;
        }
    }

    /** Model information. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ModelInfo {
        public String id;
        public String name;
        public ModelCapabilities capabilities;
    }

    /** Session metadata. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class SessionMetadata {
        @JsonProperty("sessionId") public String sessionId;
        @JsonProperty("startTime") public String startTime;
        @JsonProperty("modifiedTime") public String modifiedTime;
        public String summary;
        @JsonProperty("isRemote") public boolean isRemote;
    }

    /** Session lifecycle event types. */
    public enum SessionLifecycleEventType {
        @JsonProperty("session.created") SESSION_CREATED,
        @JsonProperty("session.deleted") SESSION_DELETED,
        @JsonProperty("session.updated") SESSION_UPDATED,
        @JsonProperty("session.foreground") SESSION_FOREGROUND,
        @JsonProperty("session.background") SESSION_BACKGROUND
    }

    /** Session lifecycle event. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class SessionLifecycleEvent {
        public String type;
        @JsonProperty("sessionId") public String sessionId;
        public Map<String, Object> metadata;
    }

    /** Session event (generic). */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class SessionEvent {
        public String type;
        public Map<String, Object> data;
    }

    /** Functional interface for session lifecycle handlers. */
    @FunctionalInterface
    public interface SessionLifecycleHandler {
        void handle(SessionLifecycleEvent event);
    }

    /** Functional interface for session event handlers. */
    @FunctionalInterface
    public interface SessionEventHandler {
        void handle(SessionEvent event);
    }

    /** Error encountered during stop(). */
    public static class StopError {
        public String message;
        public StopError(String message) { this.message = message; }
    }
}
