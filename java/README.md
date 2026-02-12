# GitHub Copilot Supercharged SDK for Java

Java SDK for the GitHub Copilot CLI, enabling programmatic interaction with the Copilot agent runtime.

## Requirements

- Java 17+
- Maven 3.8+ or Gradle 8+

## Installation

### Maven

```xml
<dependency>
    <groupId>com.github.copilot.supercharged</groupId>
    <artifactId>copilot-sdk-supercharged</artifactId>
    <version>0.1.0</version>
</dependency>
```

### Gradle

```groovy
implementation 'com.github.copilot.supercharged:copilot-sdk-supercharged:0.1.0'
```

## Quick Start

```java
import com.github.copilot.*;
import com.github.copilot.Types.*;

public class QuickStart {
    public static void main(String[] args) throws Exception {
        // Create a client (auto-starts CLI server)
        CopilotClient client = new CopilotClient();

        // Create a session
        CopilotSession session = client.createSession(
            new SessionConfig().model("gpt-4")
        );

        // Subscribe to events
        session.on(event -> {
            if ("assistant.message".equals(event.type)) {
                System.out.println("Assistant: " + event.data.get("content"));
            }
        });

        // Send a message and wait for response
        SessionEvent response = session.sendAndWait(
            new MessageOptions("What is 2+2?")
        );
        System.out.println("Answer: " + response.data.get("content"));

        // Clean up
        session.destroy();
        client.stop();
    }
}
```

## Custom Tools

```java
Tool weatherTool = DefineTool.create("get_weather")
    .description("Get weather for a location")
    .parameters(Map.of(
        "type", "object",
        "properties", Map.of(
            "location", Map.of("type", "string", "description", "City name")
        ),
        "required", List.of("location")
    ))
    .handler((args, invocation) -> {
        Map<String, Object> argMap = (Map<String, Object>) args;
        return "72°F in " + argMap.get("location");
    })
    .build();

CopilotSession session = client.createSession(
    new SessionConfig().tools(List.of(weatherTool))
);
```

## Custom Provider (BYOK)

```java
ProviderConfig provider = new ProviderConfig();
provider.type = "openai";
provider.baseUrl = "http://localhost:11434/v1";

CopilotSession session = client.createSession(
    new SessionConfig().model("llama3").provider(provider)
);
```

## Streaming

```java
CopilotSession session = client.createSession(
    new SessionConfig().streaming(true)
);

session.on("assistant.message_delta", event -> {
    System.out.print(event.data.get("deltaContent"));
});
```

## API Reference

### CopilotClient

| Method | Description |
|--------|-------------|
| `start()` | Start CLI server and connect |
| `stop()` | Graceful shutdown |
| `forceStop()` | Force shutdown |
| `createSession(config)` | Create a new session |
| `resumeSession(id, config)` | Resume an existing session |
| `listSessions()` | List all sessions |
| `deleteSession(id)` | Delete a session |
| `ping(message)` | Ping the server |
| `listModels()` | List available models |
| `getState()` | Get connection state |
| `on(handler)` | Subscribe to lifecycle events |

### CopilotSession

| Method | Description |
|--------|-------------|
| `send(options)` | Send a message |
| `sendAndWait(options)` | Send and wait for idle |
| `on(handler)` | Subscribe to all events |
| `on(type, handler)` | Subscribe to specific event type |
| `getMessages()` | Get conversation history |
| `abort()` | Abort current processing |
| `destroy()` | Destroy the session |

## License

MIT
