package GitHub::Copilot::Session;
# Copyright (c) Microsoft Corporation. All rights reserved.

use strict;
use warnings;
use Carp qw(croak);
use JSON::PP;
use Scalar::Util qw(blessed);
use Time::HiRes qw(time sleep);

use GitHub::Copilot::Types;

=head1 NAME

GitHub::Copilot::Session - A single conversation session with the Copilot CLI

=head1 DESCRIPTION

Represents a single conversation session. Sessions maintain conversation state,
handle events, manage tool execution, and support permission and hook handlers.

Sessions are created via C<< GitHub::Copilot::Client->create_session() >> or
resumed via C<< GitHub::Copilot::Client->resume_session() >>.

=cut

my $json = JSON::PP->new->utf8->canonical->allow_blessed->convert_blessed;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        session_id         => $args{session_id} // croak("session_id required"),
        _client            => $args{client}     // croak("client required"),
        workspace_path     => $args{workspace_path},
        _event_handlers    => [],
        _tool_handlers     => {},
        _permission_handler => undef,
        _user_input_handler => undef,
        _hooks             => undef,
    }, $class;

    return $self;
}

# --------------------------------------------------------------------------
# Accessors
# --------------------------------------------------------------------------

sub session_id     { return $_[0]->{session_id} }
sub workspace_path { return $_[0]->{workspace_path} }

# --------------------------------------------------------------------------
# Sending messages
# --------------------------------------------------------------------------

sub send {
    my ($self, $options) = @_;

    my $prompt = ref($options) && blessed($options) ? $options->prompt : $options->{prompt};
    my $attachments;
    my $mode;

    if (ref($options) && blessed($options)) {
        $attachments = $options->attachments;
        $mode        = $options->mode;
    } else {
        $attachments = $options->{attachments};
        $mode        = $options->{mode};
    }

    my %payload = (
        sessionId => $self->{session_id},
        prompt    => $prompt,
    );
    $payload{attachments} = $attachments if defined $attachments;
    $payload{mode}        = $mode        if defined $mode;

    my $response = $self->{_client}->request('session.send', \%payload);
    return $response->{messageId};
}

sub send_and_wait {
    my ($self, $options, $timeout) = @_;
    $timeout //= 60;

    my $idle_received = 0;
    my $error_event;
    my $last_assistant_message;

    # Register event handler BEFORE sending to avoid race condition
    my $unsubscribe = $self->on(sub {
        my ($event) = @_;
        if ($event->type eq 'assistant.message') {
            $last_assistant_message = $event;
        } elsif ($event->type eq 'session.idle') {
            $idle_received = 1;
        } elsif ($event->type eq 'session.error') {
            $error_event = $event;
            $idle_received = 1;  # Also unblock on error
        }
    });

    eval {
        $self->send($options);

        my $deadline = time() + $timeout;

        while (!$idle_received) {
            # Process incoming messages from the JSON-RPC client
            $self->{_client}->process_incoming();

            if (time() > $deadline) {
                croak "Timeout after ${timeout}s waiting for session.idle";
            }

            # Small sleep to avoid busy-waiting
            sleep(0.01);
        }
    };
    my $err = $@;

    # Always unsubscribe
    $unsubscribe->();

    if ($err) {
        die $err;
    }

    if ($error_event) {
        my $msg = $error_event->data->{message} // 'Unknown session error';
        croak "Session error: $msg";
    }

    return $last_assistant_message;
}

# --------------------------------------------------------------------------
# Event subscription
# --------------------------------------------------------------------------

sub on {
    my ($self, $handler) = @_;
    croak "handler must be a code reference" unless ref($handler) eq 'CODE';

    push @{ $self->{_event_handlers} }, $handler;

    # Return unsubscribe function
    return sub {
        $self->{_event_handlers} = [
            grep { $_ != $handler } @{ $self->{_event_handlers} }
        ];
    };
}

sub _dispatch_event {
    my ($self, $event) = @_;

    for my $handler (@{ $self->{_event_handlers} }) {
        eval { $handler->($event) };
        if ($@) {
            warn "Error in session event handler: $@";
        }
    }
}

# --------------------------------------------------------------------------
# Tool registration
# --------------------------------------------------------------------------

sub register_tools {
    my ($self, $tools) = @_;
    $self->{_tool_handlers} = {};
    return unless $tools && ref($tools) eq 'ARRAY';

    for my $tool (@$tools) {
        next unless $tool->name && $tool->handler;
        $self->{_tool_handlers}{ $tool->name } = $tool->handler;
    }
}

sub get_tool_handler {
    my ($self, $name) = @_;
    return $self->{_tool_handlers}{$name};
}

# --------------------------------------------------------------------------
# Permission handling
# --------------------------------------------------------------------------

sub register_permission_handler {
    my ($self, $handler) = @_;
    $self->{_permission_handler} = $handler;
}

sub _handle_permission_request {
    my ($self, $request) = @_;

    if (!$self->{_permission_handler}) {
        return { kind => 'denied-no-approval-rule-and-could-not-request-from-user' };
    }

    my $result;
    eval {
        $result = $self->{_permission_handler}->($request, { session_id => $self->{session_id} });
    };
    if ($@) {
        return { kind => 'denied-no-approval-rule-and-could-not-request-from-user' };
    }

    return $result;
}

# --------------------------------------------------------------------------
# User input handling
# --------------------------------------------------------------------------

sub register_user_input_handler {
    my ($self, $handler) = @_;
    $self->{_user_input_handler} = $handler;
}

sub _handle_user_input_request {
    my ($self, $request) = @_;

    croak "User input requested but no handler registered"
        unless $self->{_user_input_handler};

    my $input_request = GitHub::Copilot::Types::UserInputRequest->new(
        question      => $request->{question} // '',
        choices       => $request->{choices}  // [],
        allowFreeform => $request->{allowFreeform} // 1,
    );

    my $result = $self->{_user_input_handler}->(
        $input_request,
        { session_id => $self->{session_id} },
    );

    return $result;
}

# --------------------------------------------------------------------------
# Hooks handling
# --------------------------------------------------------------------------

sub register_hooks {
    my ($self, $hooks) = @_;
    $self->{_hooks} = $hooks;
}

sub _handle_hooks_invoke {
    my ($self, $hook_type, $input) = @_;

    return undef unless $self->{_hooks};

    my %handler_map = (
        preToolUse           => $self->{_hooks}{on_pre_tool_use},
        postToolUse          => $self->{_hooks}{on_post_tool_use},
        userPromptSubmitted  => $self->{_hooks}{on_user_prompt_submitted},
        sessionStart         => $self->{_hooks}{on_session_start},
        sessionEnd           => $self->{_hooks}{on_session_end},
        errorOccurred        => $self->{_hooks}{on_error_occurred},
    );

    my $handler = $handler_map{$hook_type};
    return undef unless $handler;

    my $result;
    eval {
        $result = $handler->($input, { session_id => $self->{session_id} });
    };
    if ($@) {
        warn "Hook handler error ($hook_type): $@";
        return undef;
    }

    return $result;
}

# --------------------------------------------------------------------------
# Session history
# --------------------------------------------------------------------------

sub get_messages {
    my ($self) = @_;

    my $response = $self->{_client}->request(
        'session.getMessages',
        { sessionId => $self->{session_id} },
    );

    my @events;
    for my $e (@{ $response->{events} // [] }) {
        push @events, GitHub::Copilot::Types::SessionEvent->from_hashref($e);
    }
    return \@events;
}

# --------------------------------------------------------------------------
# Session lifecycle
# --------------------------------------------------------------------------

sub destroy {
    my ($self) = @_;

    $self->{_client}->request(
        'session.destroy',
        { sessionId => $self->{session_id} },
    );

    $self->{_event_handlers}     = [];
    $self->{_tool_handlers}      = {};
    $self->{_permission_handler} = undef;
    $self->{_user_input_handler} = undef;
    $self->{_hooks}              = undef;
}

sub abort {
    my ($self) = @_;

    $self->{_client}->request(
        'session.abort',
        { sessionId => $self->{session_id} },
    );
}

1;

__END__

=head1 METHODS

=head2 new(%args)

Internal constructor. Use C<< $client->create_session() >> instead.

=head2 session_id()

Returns the session ID string.

=head2 workspace_path()

Returns the workspace path (undef if infinite sessions disabled).

=head2 send($options)

Send a message. $options is a MessageOptions object or hashref with 'prompt' key.
Returns the messageId string.

=head2 send_and_wait($options, $timeout)

Send a message and block until the session becomes idle. Returns the last
assistant.message SessionEvent, or undef if none received.

$timeout is in seconds (default: 60).

=head2 on($handler)

Subscribe to session events. $handler is a coderef receiving a SessionEvent.
Returns an unsubscribe coderef.

=head2 register_tools($tools)

Register tool handlers. $tools is an arrayref of Tool objects.

=head2 get_tool_handler($name)

Get a registered tool handler by name.

=head2 get_messages()

Retrieve conversation history. Returns arrayref of SessionEvent objects.

=head2 destroy()

Destroy the session and release resources.

=head2 abort()

Abort the currently processing message.

=cut
