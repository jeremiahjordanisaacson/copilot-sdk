/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/
package com.github.copilot;

import com.github.copilot.Types.Tool;
import com.github.copilot.Types.ToolHandler;
import java.util.Map;

/**
 * Helper class for defining tools with a builder pattern.
 *
 * <pre>{@code
 * Tool weatherTool = DefineTool.create("get_weather")
 *     .description("Get weather for a location")
 *     .parameters(Map.of(
 *         "type", "object",
 *         "properties", Map.of(
 *             "location", Map.of("type", "string", "description", "City name")
 *         ),
 *         "required", List.of("location")
 *     ))
 *     .handler((args, invocation) -> {
 *         Map<String, Object> arguments = (Map<String, Object>) args;
 *         return "72°F in " + arguments.get("location");
 *     })
 *     .build();
 * }</pre>
 */
public class DefineTool {
    private String name;
    private String description;
    private Map<String, Object> parameters;
    private ToolHandler handler;

    private DefineTool(String name) {
        this.name = name;
    }

    /** Creates a new tool builder with the given name. */
    public static DefineTool create(String name) {
        return new DefineTool(name);
    }

    public DefineTool description(String description) {
        this.description = description;
        return this;
    }

    public DefineTool parameters(Map<String, Object> parameters) {
        this.parameters = parameters;
        return this;
    }

    public DefineTool handler(ToolHandler handler) {
        this.handler = handler;
        return this;
    }

    /** Builds the Tool instance. */
    public Tool build() {
        if (name == null) throw new IllegalStateException("Tool name is required");
        if (handler == null) throw new IllegalStateException("Tool handler is required");
        return new Tool(name, description, parameters, handler);
    }
}
