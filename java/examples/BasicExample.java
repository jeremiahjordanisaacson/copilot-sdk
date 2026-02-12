/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

import com.github.copilot.*;
import com.github.copilot.Types.*;

import java.util.List;
import java.util.Map;

/**
 * Basic example of using the GitHub Copilot Java SDK.
 */
public class BasicExample {

    static final Map<String, String> FACTS = Map.of(
        "javascript", "JavaScript was created in 10 days by Brendan Eich in 1995.",
        "java", "Java was created by James Gosling at Sun Microsystems in 1995.",
        "node", "Node.js lets you run JavaScript outside the browser using the V8 engine."
    );

    @SuppressWarnings("unchecked")
    public static void main(String[] args) throws Exception {
        System.out.println("Starting Copilot SDK Java Example\n");

        // Define a custom tool
        Tool lookupFactTool = DefineTool.create("lookup_fact")
            .description("Returns a fun fact about a given topic.")
            .parameters(Map.of(
                "type", "object",
                "properties", Map.of(
                    "topic", Map.of("type", "string", "description", "Topic to look up")
                ),
                "required", List.of("topic")
            ))
            .handler((arguments, invocation) -> {
                Map<String, Object> argMap = (Map<String, Object>) arguments;
                String topic = ((String) argMap.get("topic")).toLowerCase();
                return FACTS.getOrDefault(topic, "No fact stored for " + topic + ".");
            })
            .build();

        // Create client - will auto-start CLI server
        CopilotClient client = new CopilotClient(
            new CopilotClientOptions().logLevel("info")
        );

        CopilotSession session = client.createSession(
            new SessionConfig().tools(List.of(lookupFactTool))
        );
        System.out.println("Session created: " + session.getSessionId() + "\n");

        // Listen to events
        session.on(event ->
            System.out.println("Event [" + event.type + "]: " + event.data)
        );

        // Send a simple message
        System.out.println("Sending message...");
        SessionEvent result1 = session.sendAndWait(new MessageOptions("Tell me 2+2"));
        if (result1 != null) {
            System.out.println("Response: " + result1.data.get("content") + "\n");
        }

        // Send a message that uses the tool
        System.out.println("Sending follow-up message...");
        SessionEvent result2 = session.sendAndWait(
            new MessageOptions("Use lookup_fact to tell me about 'java'")
        );
        if (result2 != null) {
            System.out.println("Response: " + result2.data.get("content") + "\n");
        }

        // Clean up
        session.destroy();
        client.stop();
        System.out.println("Done!");
    }
}
