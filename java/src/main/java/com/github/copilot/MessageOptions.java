/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot;

import java.util.List;
import java.util.Map;

/**
 * Options for sending a message to a session.
 */
public class MessageOptions {
    private String prompt;
    private List<Map<String, Object>> attachments;
    private String mode;

    public MessageOptions(String prompt) {
        this.prompt = prompt;
    }

    public MessageOptions prompt(String prompt) { this.prompt = prompt; return this; }
    public MessageOptions attachments(List<Map<String, Object>> attachments) { this.attachments = attachments; return this; }
    public MessageOptions mode(String mode) { this.mode = mode; return this; }

    public String getPrompt() { return prompt; }
    public List<Map<String, Object>> getAttachments() { return attachments; }
    public String getMode() { return mode; }
}
