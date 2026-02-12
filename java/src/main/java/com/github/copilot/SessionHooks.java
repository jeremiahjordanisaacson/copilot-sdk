/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot;

import java.util.Map;

/**
 * Configuration for session hooks - lifecycle event interceptors.
 */
public class SessionHooks {
    private HookHandler onPreToolUse;
    private HookHandler onPostToolUse;
    private HookHandler onUserPromptSubmitted;
    private HookHandler onSessionStart;
    private HookHandler onSessionEnd;
    private HookHandler onErrorOccurred;

    /** Generic hook handler. */
    @FunctionalInterface
    public interface HookHandler {
        Map<String, Object> handle(Map<String, Object> input, String sessionId) throws Exception;
    }

    public SessionHooks onPreToolUse(HookHandler handler) { this.onPreToolUse = handler; return this; }
    public SessionHooks onPostToolUse(HookHandler handler) { this.onPostToolUse = handler; return this; }
    public SessionHooks onUserPromptSubmitted(HookHandler handler) { this.onUserPromptSubmitted = handler; return this; }
    public SessionHooks onSessionStart(HookHandler handler) { this.onSessionStart = handler; return this; }
    public SessionHooks onSessionEnd(HookHandler handler) { this.onSessionEnd = handler; return this; }
    public SessionHooks onErrorOccurred(HookHandler handler) { this.onErrorOccurred = handler; return this; }

    public HookHandler getOnPreToolUse() { return onPreToolUse; }
    public HookHandler getOnPostToolUse() { return onPostToolUse; }
    public HookHandler getOnUserPromptSubmitted() { return onUserPromptSubmitted; }
    public HookHandler getOnSessionStart() { return onSessionStart; }
    public HookHandler getOnSessionEnd() { return onSessionEnd; }
    public HookHandler getOnErrorOccurred() { return onErrorOccurred; }

    public boolean hasAnyHook() {
        return onPreToolUse != null || onPostToolUse != null || onUserPromptSubmitted != null
            || onSessionStart != null || onSessionEnd != null || onErrorOccurred != null;
    }

    /** Get handler by hook type name. */
    public HookHandler getHandler(String hookType) {
        return switch (hookType) {
            case "preToolUse" -> onPreToolUse;
            case "postToolUse" -> onPostToolUse;
            case "userPromptSubmitted" -> onUserPromptSubmitted;
            case "sessionStart" -> onSessionStart;
            case "sessionEnd" -> onSessionEnd;
            case "errorOccurred" -> onErrorOccurred;
            default -> null;
        };
    }
}
