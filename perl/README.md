# GitHub Copilot Supercharged Perl SDK

Perl SDK for the GitHub Copilot CLI. Communicates with the Copilot CLI server
via JSON-RPC 2.0 over stdio, following the same patterns as the official
Node.js, Python, Go, and .NET SDKs.

## Requirements

- Perl 5.20 or later
- [GitHub Copilot CLI](https://github.com/github/copilot) installed and authenticated
- CPAN modules: `Moo`, `JSON::PP`, `UUID::Tiny`, `File::Which`, `Thread::Queue`

## Installation

```bash
# Install dependencies
cpanm Moo JSON::PP UUID::Tiny File::Which Thread::Queue

# From the SDK directory
cd perl
perl Makefile.PL
make
make test
make install
```

## Quick Start

```perl
use GitHub::Copilot::Client;
use GitHub::Copilot::Types;

# Create and start the client
my $client = GitHub::Copilot::Client->new();
$client->start();

# Create a session
my $session = $client->create_session();

# Subscribe to events
$session->on(sub {
    my ($event) = @_;
    if ($event->type eq 'assistant.message') {
        print "Assistant: " . $event->data->{content} . "\n";
    }
});

# Send a message and wait for the response
my $response = $session->send_and_wait(
    { prompt => 'What is 2+2?' },
);

# Clean up
$session->destroy();
$client->stop();
```

## Architecture

The SDK consists of the following modules:

| Module | Description |
|--------|-------------|
| `GitHub::Copilot::Client` | Main entry point. Spawns the CLI process and manages sessions. |
| `GitHub::Copilot::Session` | Represents a conversation session. Send messages, subscribe to events. |
| `GitHub::Copilot::JsonRpcClient` | JSON-RPC 2.0 client using Content-Length header framing over stdio. |
| `GitHub::Copilot::Types` | Moo-based data classes for all SDK types. |
| `GitHub::Copilot::DefineTool` | Helper function for defining custom tools. |
| `GitHub::Copilot::SdkProtocolVersion` | Protocol version constant (must match the CLI server). |

## Client Options

```perl
my $client = GitHub::Copilot::Client->new(
    cli_path           => '/usr/local/bin/copilot',  # Auto-detected if omitted
    cli_args           => ['--extra-flag'],           # Extra CLI arguments
    cwd                => '/path/to/workspace',       # Working directory
    log_level          => 'debug',                    # none|error|warning|info|debug|all
    auto_start         => 1,                          # Auto-start on first use
    github_token       => $ENV{GITHUB_TOKEN},         # GitHub auth token
    use_logged_in_user => 1,                          # Use stored OAuth/gh CLI auth
    env                => { PATH => '/usr/bin' },     # Custom environment
);
```

## Session Configuration

```perl
use GitHub::Copilot::Types;
use GitHub::Copilot::DefineTool qw(define_tool);

my $session = $client->create_session(
    GitHub::Copilot::Types::SessionConfig->new(
        model             => 'gpt-4o',
        working_directory => '/path/to/project',
        tools             => [$my_tool],
        streaming         => 1,
        system_message    => { mode => 'append', content => 'Be concise.' },
        available_tools   => ['read_file', 'write_file', 'get_weather'],
        on_permission_request => sub {
            my ($request, $ctx) = @_;
            return { kind => 'approved' };
        },
        on_user_input_request => sub {
            my ($request, $ctx) = @_;
            print "Agent asks: " . $request->question . "\n";
            print "> ";
            my $answer = <STDIN>;
            chomp $answer;
            return { answer => $answer, wasFreeform => 1 };
        },
        hooks => {
            on_pre_tool_use => sub {
                my ($input, $ctx) = @_;
                print "About to use tool: $input->{toolName}\n";
                return { permissionDecision => 'allow' };
            },
        },
    ),
);
```

## Defining Tools

```perl
use GitHub::Copilot::DefineTool qw(define_tool);

my $tool = define_tool(
    name        => 'search_codebase',
    description => 'Search the codebase for a pattern',
    parameters  => {
        type       => 'object',
        properties => {
            pattern => {
                type        => 'string',
                description => 'Regex pattern to search for',
            },
        },
        required => ['pattern'],
    },
    handler => sub {
        my ($args, $invocation) = @_;
        # $args->{pattern} contains the search pattern
        # $invocation->sessionId, ->toolCallId, ->toolName available
        my @results = search($args->{pattern});
        return join("\n", @results);
    },
);
```

Tool handlers receive:

1. `$args` - Parsed arguments hashref
2. `$invocation` - A `GitHub::Copilot::Types::ToolInvocation` object

Handlers can return:
- A plain string (wrapped as success)
- A hashref (JSON-encoded as success)
- A `GitHub::Copilot::Types::ToolResultObject` (passed through)
- `undef` (treated as failure)

## Event Handling

```perl
# Subscribe to all events
my $unsub = $session->on(sub {
    my ($event) = @_;
    my $type = $event->type;
    my $data = $event->data;

    if ($type eq 'assistant.message') {
        print "Final: $data->{content}\n";
    }
    elsif ($type eq 'assistant.message_delta') {
        print $data->{deltaContent};  # Streaming
    }
    elsif ($type eq 'tool.executing') {
        print "Tool: $data->{toolName}\n";
    }
    elsif ($type eq 'session.idle') {
        print "Session is idle.\n";
    }
    elsif ($type eq 'session.error') {
        warn "Error: $data->{message}\n";
    }
});

# Unsubscribe when done
$unsub->();
```

## Session Lifecycle

```perl
# Send without waiting
my $msg_id = $session->send({ prompt => 'Hello' });

# Send and wait for completion (blocking)
my $response = $session->send_and_wait(
    { prompt => 'Explain this code' },
    120,  # timeout in seconds
);

# Retrieve conversation history
my $events = $session->get_messages();

# Abort a long-running request
$session->abort();

# Resume a previous session
my $session = $client->resume_session($session_id);

# Delete a session permanently
$client->delete_session($session_id);

# List all sessions
my $sessions = $client->list_sessions();
```

## Wire Protocol

The SDK communicates with the Copilot CLI using JSON-RPC 2.0 over stdio with
Content-Length header framing (the same format used by LSP):

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":"uuid","method":"ping","params":{"message":"hello"}}
```

The CLI is spawned with flags:
```
copilot --headless --no-auto-update --log-level info --stdio
```

Key JSON-RPC methods:
- `ping` - Health check, returns protocol version
- `session.create` / `session.resume` / `session.destroy` - Session lifecycle
- `session.send` - Send a message
- `session.getMessages` - Retrieve history
- `models.list` - List available models

Server-initiated requests handled by the SDK:
- `tool.call` - Execute a custom tool
- `permission.request` - Request permission for an operation
- `userInput.request` - Request user input (ask_user)
- `hooks.invoke` - Invoke a session hook

Server-initiated notifications:
- `session.event` - Session events (assistant.message, session.idle, etc.)

## Examples

See `examples/basic_example.pl` for a complete working example.

## License

MIT License. Copyright (c) Microsoft Corporation.
