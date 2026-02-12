package GitHub::Copilot::Client;
# Copyright (c) Microsoft Corporation. All rights reserved.

use strict;
use warnings;
use Carp qw(croak);
use IPC::Open3;
use Symbol 'gensym';
use File::Which qw(which);
use JSON::PP;
use Scalar::Util qw(blessed);

use GitHub::Copilot::JsonRpcClient;
use GitHub::Copilot::Session;
use GitHub::Copilot::SdkProtocolVersion qw(get_sdk_protocol_version);
use GitHub::Copilot::Types;

our $VERSION = '0.01';

=head1 NAME

GitHub::Copilot::Client - Main client for interacting with the Copilot CLI

=head1 DESCRIPTION

The CopilotClient manages the connection to the Copilot CLI server and provides
methods to create and manage conversation sessions. It spawns a CLI server
process and communicates via JSON-RPC 2.0 over stdio.

=head1 SYNOPSIS

    use GitHub::Copilot::Client;

    my $client = GitHub::Copilot::Client->new(
        cli_path => '/usr/local/bin/copilot',
    );
    $client->start();

    my $session = $client->create_session(
        GitHub::Copilot::Types::SessionConfig->new(
            model => 'gpt-4o',
        )
    );

    my $response = $session->send_and_wait(
        GitHub::Copilot::Types::MessageOptions->new(
            prompt => 'What is 2+2?',
        )
    );

    print "Assistant: " . $response->data->{content} . "\n" if $response;

    $session->destroy();
    $client->stop();

=cut

my $json = JSON::PP->new->utf8->canonical->allow_blessed->convert_blessed;

sub new {
    my ($class, %args) = @_;

    my $cli_path   = $args{cli_path};
    my $cli_args   = $args{cli_args}   // [];
    my $cwd        = $args{cwd};
    my $log_level  = $args{log_level}  // 'info';
    my $auto_start = exists $args{auto_start} ? $args{auto_start} : 1;
    my $github_token      = $args{github_token};
    my $use_logged_in_user = $args{use_logged_in_user};

    # Default use_logged_in_user: false when github_token provided, true otherwise
    if (!defined $use_logged_in_user) {
        $use_logged_in_user = defined $github_token ? 0 : 1;
    }

    # Try to find CLI if not specified
    if (!defined $cli_path) {
        $cli_path = which('copilot') // which('github-copilot');
        croak "Copilot CLI not found. Provide cli_path or install copilot on PATH."
            unless defined $cli_path;
    }

    croak "Copilot CLI not found at '$cli_path'" unless -e $cli_path;

    my $self = bless {
        cli_path           => $cli_path,
        cli_args           => $cli_args,
        cwd                => $cwd,
        log_level          => $log_level,
        auto_start         => $auto_start,
        github_token       => $github_token,
        use_logged_in_user => $use_logged_in_user,
        env                => $args{env},
        _process_pid       => undef,
        _client            => undef,
        _state             => 'disconnected',
        _sessions          => {},
        _models_cache      => undef,
    }, $class;

    return $self;
}

# --------------------------------------------------------------------------
# Connection lifecycle
# --------------------------------------------------------------------------

sub start {
    my ($self) = @_;
    return if $self->{_state} eq 'connected';

    $self->{_state} = 'connecting';

    eval {
        $self->_start_cli_server();
        $self->_setup_handlers();
        $self->_verify_protocol_version();
        $self->{_state} = 'connected';
    };
    if ($@) {
        $self->{_state} = 'error';
        die $@;
    }
}

sub stop {
    my ($self) = @_;
    my @errors;

    # Destroy all sessions
    for my $session (values %{ $self->{_sessions} }) {
        eval { $session->destroy() };
        if ($@) {
            push @errors, "Failed to destroy session " . $session->session_id . ": $@";
        }
    }
    $self->{_sessions} = {};

    # Stop JSON-RPC client
    if ($self->{_client}) {
        eval { $self->{_client}->stop() };
        $self->{_client} = undef;
    }

    # Kill CLI process
    if ($self->{_process_pid}) {
        kill('TERM', $self->{_process_pid});
        waitpid($self->{_process_pid}, 0);
        $self->{_process_pid} = undef;
    }

    # Close filehandles
    for my $fh_key (qw(_stdin_fh _stdout_fh _stderr_fh)) {
        if ($self->{$fh_key}) {
            eval { close($self->{$fh_key}) };
            $self->{$fh_key} = undef;
        }
    }

    $self->{_state} = 'disconnected';
    $self->{_models_cache} = undef;

    return \@errors;
}

sub get_state {
    my ($self) = @_;
    return $self->{_state};
}

# --------------------------------------------------------------------------
# Session management
# --------------------------------------------------------------------------

sub create_session {
    my ($self, $config) = @_;
    $config //= GitHub::Copilot::Types::SessionConfig->new();

    $self->_ensure_connected();

    my $payload = $config->to_wire();

    my $response = $self->{_client}->request('session.create', $payload);

    my $session_id     = $response->{sessionId};
    my $workspace_path = $response->{workspacePath};

    my $session = GitHub::Copilot::Session->new(
        session_id     => $session_id,
        client         => $self->{_client},
        workspace_path => $workspace_path,
    );

    # Register tools
    if ($config->tools && @{ $config->tools }) {
        $session->register_tools($config->tools);
    }

    # Register permission handler
    if ($config->on_permission_request) {
        $session->register_permission_handler($config->on_permission_request);
    }

    # Register user input handler
    if ($config->on_user_input_request) {
        $session->register_user_input_handler($config->on_user_input_request);
    }

    # Register hooks
    if ($config->hooks) {
        $session->register_hooks($config->hooks);
    }

    $self->{_sessions}{$session_id} = $session;
    return $session;
}

sub resume_session {
    my ($self, $session_id, $config) = @_;
    $config //= GitHub::Copilot::Types::SessionConfig->new();

    $self->_ensure_connected();

    my $payload = $config->to_wire();
    $payload->{sessionId} = $session_id;

    my $response = $self->{_client}->request('session.resume', $payload);

    my $resumed_id     = $response->{sessionId};
    my $workspace_path = $response->{workspacePath};

    my $session = GitHub::Copilot::Session->new(
        session_id     => $resumed_id,
        client         => $self->{_client},
        workspace_path => $workspace_path,
    );

    if ($config->tools && @{ $config->tools }) {
        $session->register_tools($config->tools);
    }
    if ($config->on_permission_request) {
        $session->register_permission_handler($config->on_permission_request);
    }
    if ($config->on_user_input_request) {
        $session->register_user_input_handler($config->on_user_input_request);
    }
    if ($config->hooks) {
        $session->register_hooks($config->hooks);
    }

    $self->{_sessions}{$resumed_id} = $session;
    return $session;
}

sub delete_session {
    my ($self, $session_id) = @_;
    $self->_ensure_connected();

    my $response = $self->{_client}->request('session.delete', { sessionId => $session_id });

    if (!$response->{success}) {
        my $error = $response->{error} // 'Unknown error';
        croak "Failed to delete session $session_id: $error";
    }

    delete $self->{_sessions}{$session_id};
}

sub list_sessions {
    my ($self) = @_;
    $self->_ensure_connected();

    my $response = $self->{_client}->request('session.list', {});
    my @sessions;
    for my $s (@{ $response->{sessions} // [] }) {
        push @sessions, GitHub::Copilot::Types::SessionMetadata->from_hashref($s);
    }
    return \@sessions;
}

# --------------------------------------------------------------------------
# Ping and status
# --------------------------------------------------------------------------

sub ping {
    my ($self, $message) = @_;
    $self->_ensure_connected();

    my $result = $self->{_client}->request('ping', { message => $message });
    return GitHub::Copilot::Types::PingResponse->from_hashref($result);
}

sub get_status {
    my ($self) = @_;
    $self->_ensure_connected();
    return $self->{_client}->request('status.get', {});
}

sub get_auth_status {
    my ($self) = @_;
    $self->_ensure_connected();
    return $self->{_client}->request('auth.getStatus', {});
}

sub list_models {
    my ($self) = @_;
    $self->_ensure_connected();

    if ($self->{_models_cache}) {
        return [ @{ $self->{_models_cache} } ];
    }

    my $response = $self->{_client}->request('models.list', {});
    my @models;
    for my $m (@{ $response->{models} // [] }) {
        push @models, GitHub::Copilot::Types::ModelInfo->from_hashref($m);
    }

    $self->{_models_cache} = \@models;
    return [ @models ];
}

# --------------------------------------------------------------------------
# Internal: start CLI server process
# --------------------------------------------------------------------------

sub _start_cli_server {
    my ($self) = @_;

    my @args = (
        @{ $self->{cli_args} },
        '--headless',
        '--no-auto-update',
        '--log-level', $self->{log_level},
        '--stdio',
    );

    # Auth flags
    if (defined $self->{github_token}) {
        push @args, '--auth-token-env', 'COPILOT_SDK_AUTH_TOKEN';
    }
    if (!$self->{use_logged_in_user}) {
        push @args, '--no-auto-login';
    }

    # Set up environment
    my %env;
    if ($self->{env}) {
        %env = %{ $self->{env} };
    } else {
        %env = %ENV;
    }
    if (defined $self->{github_token}) {
        $env{COPILOT_SDK_AUTH_TOKEN} = $self->{github_token};
    }
    delete $env{NODE_DEBUG};

    # Build command
    my @cmd;
    if ($self->{cli_path} =~ /\.js$/) {
        my $node = $ENV{NODE_PATH} ? "$ENV{NODE_PATH}/node" : 'node';
        @cmd = ($node, $self->{cli_path}, @args);
    } else {
        @cmd = ($self->{cli_path}, @args);
    }

    # Save current dir and environment, spawn process
    my $stderr_fh = gensym();
    local %ENV = %env;

    my $pid = open3(
        my $stdin_fh,
        my $stdout_fh,
        $stderr_fh,
        @cmd,
    );

    $self->{_process_pid} = $pid;
    $self->{_stdin_fh}    = $stdin_fh;
    $self->{_stdout_fh}   = $stdout_fh;
    $self->{_stderr_fh}   = $stderr_fh;

    # Create JSON-RPC client over the stdio pipes
    $self->{_client} = GitHub::Copilot::JsonRpcClient->new(
        stdin  => $stdin_fh,
        stdout => $stdout_fh,
    );
    $self->{_client}->start();

    # Start a thread to read stderr and forward it
    threads->create(sub {
        while (my $line = <$stderr_fh>) {
            chomp $line;
            print STDERR "[CLI subprocess] $line\n" if $line;
        }
    })->detach();
}

# --------------------------------------------------------------------------
# Internal: set up request/notification handlers
# --------------------------------------------------------------------------

sub _setup_handlers {
    my ($self) = @_;

    # Handle session event notifications
    $self->{_client}->set_notification_handler(sub {
        my ($method, $params) = @_;

        if ($method eq 'session.event') {
            my $session_id = $params->{sessionId};
            my $event_data = $params->{event};
            my $session = $self->{_sessions}{$session_id};
            if ($session && $event_data) {
                my $event = GitHub::Copilot::Types::SessionEvent->from_hashref($event_data);
                $session->_dispatch_event($event);
            }
        }
    });

    # Handle tool.call requests from server
    $self->{_client}->set_request_handler('tool.call', sub {
        my ($params) = @_;
        return $self->_handle_tool_call($params);
    });

    # Handle permission.request from server
    $self->{_client}->set_request_handler('permission.request', sub {
        my ($params) = @_;
        return $self->_handle_permission_request($params);
    });

    # Handle userInput.request from server
    $self->{_client}->set_request_handler('userInput.request', sub {
        my ($params) = @_;
        return $self->_handle_user_input_request($params);
    });

    # Handle hooks.invoke from server
    $self->{_client}->set_request_handler('hooks.invoke', sub {
        my ($params) = @_;
        return $self->_handle_hooks_invoke($params);
    });
}

# --------------------------------------------------------------------------
# Internal: request handlers
# --------------------------------------------------------------------------

sub _handle_tool_call {
    my ($self, $params) = @_;

    my $session_id  = $params->{sessionId};
    my $tool_call_id = $params->{toolCallId};
    my $tool_name   = $params->{toolName};
    my $arguments   = $params->{arguments};

    croak "Invalid tool call payload" unless $session_id && $tool_call_id && $tool_name;

    my $session = $self->{_sessions}{$session_id};
    croak "Unknown session $session_id" unless $session;

    my $handler = $session->get_tool_handler($tool_name);
    if (!$handler) {
        return {
            result => {
                textResultForLlm => "Tool '$tool_name' is not supported by this client instance.",
                resultType       => 'failure',
                error            => "tool '$tool_name' not supported",
                toolTelemetry    => {},
            },
        };
    }

    my $invocation = GitHub::Copilot::Types::ToolInvocation->new(
        sessionId  => $session_id,
        toolCallId => $tool_call_id,
        toolName   => $tool_name,
        arguments  => $arguments,
    );

    my $result;
    eval {
        $result = $handler->($arguments, $invocation);
    };
    if ($@) {
        return {
            result => {
                textResultForLlm => 'Invoking this tool produced an error. Detailed information is not available.',
                resultType       => 'failure',
                error            => "$@",
                toolTelemetry    => {},
            },
        };
    }

    return { result => $self->_normalize_tool_result($result) };
}

sub _normalize_tool_result {
    my ($self, $result) = @_;

    # undef
    if (!defined $result) {
        return {
            textResultForLlm => 'Tool returned no result',
            resultType       => 'failure',
            error            => 'tool returned no result',
            toolTelemetry    => {},
        };
    }

    # Already a ToolResultObject (Moo object)
    if (blessed($result) && $result->can('textResultForLlm')) {
        return $result->TO_JSON();
    }

    # Already a hashref with resultType + textResultForLlm
    if (ref($result) eq 'HASH' && exists $result->{textResultForLlm} && exists $result->{resultType}) {
        return $result;
    }

    # String result
    if (!ref($result)) {
        return {
            textResultForLlm => "$result",
            resultType       => 'success',
            toolTelemetry    => {},
        };
    }

    # Anything else: JSON-encode it
    my $text = eval { $json->encode($result) } // "$result";
    return {
        textResultForLlm => $text,
        resultType       => 'success',
        toolTelemetry    => {},
    };
}

sub _handle_permission_request {
    my ($self, $params) = @_;

    my $session_id = $params->{sessionId};
    my $perm_req   = $params->{permissionRequest};

    croak "Invalid permission request payload" unless $session_id && $perm_req;

    my $session = $self->{_sessions}{$session_id};
    croak "Unknown session $session_id" unless $session;

    my $result;
    eval {
        $result = $session->_handle_permission_request($perm_req);
    };
    if ($@) {
        return {
            result => {
                kind => 'denied-no-approval-rule-and-could-not-request-from-user',
            },
        };
    }

    return { result => $result };
}

sub _handle_user_input_request {
    my ($self, $params) = @_;

    my $session_id = $params->{sessionId};
    my $question   = $params->{question};

    croak "Invalid user input request payload" unless $session_id && $question;

    my $session = $self->{_sessions}{$session_id};
    croak "Unknown session $session_id" unless $session;

    my $result = $session->_handle_user_input_request($params);
    return {
        answer      => $result->{answer},
        wasFreeform => $result->{wasFreeform} ? \1 : \0,
    };
}

sub _handle_hooks_invoke {
    my ($self, $params) = @_;

    my $session_id = $params->{sessionId};
    my $hook_type  = $params->{hookType};
    my $input      = $params->{input};

    croak "Invalid hooks invoke payload" unless $session_id && $hook_type;

    my $session = $self->{_sessions}{$session_id};
    croak "Unknown session $session_id" unless $session;

    my $output = $session->_handle_hooks_invoke($hook_type, $input);
    return { output => $output };
}

# --------------------------------------------------------------------------
# Internal: protocol version verification
# --------------------------------------------------------------------------

sub _verify_protocol_version {
    my ($self) = @_;

    my $expected = get_sdk_protocol_version();
    my $ping_result = $self->ping();
    my $server_version = $ping_result->protocolVersion;

    if (!defined $server_version) {
        croak "SDK protocol version mismatch: SDK expects version $expected, "
            . "but server does not report a protocol version. "
            . "Please update your server to ensure compatibility.";
    }

    if ($server_version != $expected) {
        croak "SDK protocol version mismatch: SDK expects version $expected, "
            . "but server reports version $server_version. "
            . "Please update your SDK or server to ensure compatibility.";
    }
}

# --------------------------------------------------------------------------
# Internal: ensure connected
# --------------------------------------------------------------------------

sub _ensure_connected {
    my ($self) = @_;

    if (!$self->{_client}) {
        if ($self->{auto_start}) {
            $self->start();
        } else {
            croak "Client not connected. Call start() first.";
        }
    }
}

1;

__END__

=head1 METHODS

=head2 new(%args)

Create a new CopilotClient.

Arguments:

    cli_path           - Path to the Copilot CLI executable (auto-detected if omitted)
    cli_args           - Extra arguments for the CLI (arrayref)
    cwd                - Working directory for the CLI process
    log_level          - Log level: none, error, warning, info, debug, all (default: info)
    auto_start         - Auto-start on first use (default: 1)
    github_token       - GitHub token for authentication
    use_logged_in_user - Use logged-in user auth (default: 1, or 0 if github_token set)
    env                - Environment variables hashref

=head2 start()

Start the CLI server and establish a connection.

=head2 stop()

Stop the CLI server and close all sessions. Returns arrayref of error strings.

=head2 create_session($config)

Create a new session. $config is a GitHub::Copilot::Types::SessionConfig object.

=head2 resume_session($session_id, $config)

Resume an existing session by ID.

=head2 delete_session($session_id)

Delete a session permanently.

=head2 list_sessions()

List all sessions. Returns arrayref of SessionMetadata objects.

=head2 ping($message)

Ping the server. Returns a PingResponse object.

=head2 list_models()

List available models. Returns arrayref of ModelInfo objects. Results are cached.

=head2 get_state()

Get the current connection state string.

=cut
