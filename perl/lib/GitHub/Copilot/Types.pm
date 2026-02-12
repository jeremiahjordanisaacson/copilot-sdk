package GitHub::Copilot::Types;
# Copyright (c) Microsoft Corporation. All rights reserved.

use strict;
use warnings;

=head1 NAME

GitHub::Copilot::Types - Type definitions for the GitHub Copilot Perl SDK

=head1 DESCRIPTION

All Moo-based data classes used across the Copilot SDK, including session events,
permission requests, user input, tool definitions, model info, session metadata,
hooks, and configuration types.

=cut

# ============================================================================
# SessionEvent - A generic session event from the server
# ============================================================================
package GitHub::Copilot::Types::SessionEvent;
use Moo;
use Types::Standard qw(Str HashRef Any Maybe);

has type => (is => 'ro', required => 1);
has data => (is => 'ro', default => sub { {} });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        type => $hr->{type} // 'unknown',
        data => $hr->{data} // {},
    );
}

sub TO_JSON {
    my ($self) = @_;
    return { type => $self->type, data => $self->data };
}

# ============================================================================
# PermissionRequest
# ============================================================================
package GitHub::Copilot::Types::PermissionRequest;
use Moo;

has kind        => (is => 'ro', required => 1);
has toolCallId  => (is => 'ro', default => sub { undef });
has extra       => (is => 'ro', default => sub { {} });

sub from_hashref {
    my ($class, $hr) = @_;
    my %extra = %{ $hr // {} };
    my $kind       = delete $extra{kind}       // 'unknown';
    my $toolCallId = delete $extra{toolCallId};
    return $class->new(
        kind       => $kind,
        toolCallId => $toolCallId,
        extra      => \%extra,
    );
}

sub TO_JSON {
    my ($self) = @_;
    my %h = %{ $self->extra // {} };
    $h{kind}       = $self->kind;
    $h{toolCallId} = $self->toolCallId if defined $self->toolCallId;
    return \%h;
}

# ============================================================================
# PermissionRequestResult
# ============================================================================
package GitHub::Copilot::Types::PermissionRequestResult;
use Moo;

has kind  => (is => 'ro', required => 1);
has rules => (is => 'ro', default => sub { undef });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        kind  => $hr->{kind} // 'denied-no-approval-rule-and-could-not-request-from-user',
        rules => $hr->{rules},
    );
}

sub TO_JSON {
    my ($self) = @_;
    my %h = (kind => $self->kind);
    $h{rules} = $self->rules if defined $self->rules;
    return \%h;
}

# ============================================================================
# UserInputRequest
# ============================================================================
package GitHub::Copilot::Types::UserInputRequest;
use Moo;

has question      => (is => 'ro', required => 1);
has choices       => (is => 'ro', default => sub { [] });
has allowFreeform => (is => 'ro', default => sub { 1 });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        question      => $hr->{question}      // '',
        choices       => $hr->{choices}        // [],
        allowFreeform => $hr->{allowFreeform}  // 1,
    );
}

sub TO_JSON {
    my ($self) = @_;
    return {
        question      => $self->question,
        choices       => $self->choices,
        allowFreeform => $self->allowFreeform ? \1 : \0,
    };
}

# ============================================================================
# UserInputResponse
# ============================================================================
package GitHub::Copilot::Types::UserInputResponse;
use Moo;

has answer      => (is => 'ro', required => 1);
has wasFreeform => (is => 'ro', default => sub { 0 });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        answer      => $hr->{answer}      // '',
        wasFreeform => $hr->{wasFreeform} // 0,
    );
}

sub TO_JSON {
    my ($self) = @_;
    return {
        answer      => $self->answer,
        wasFreeform => $self->wasFreeform ? \1 : \0,
    };
}

# ============================================================================
# PingResponse
# ============================================================================
package GitHub::Copilot::Types::PingResponse;
use Moo;

has message         => (is => 'ro', required => 1);
has timestamp       => (is => 'ro', required => 1);
has protocolVersion => (is => 'ro', default => sub { undef });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        message         => $hr->{message}         // '',
        timestamp       => $hr->{timestamp}       // 0,
        protocolVersion => $hr->{protocolVersion},
    );
}

sub TO_JSON {
    my ($self) = @_;
    my %h = (
        message   => $self->message,
        timestamp => $self->timestamp,
    );
    $h{protocolVersion} = $self->protocolVersion if defined $self->protocolVersion;
    return \%h;
}

# ============================================================================
# ModelInfo
# ============================================================================
package GitHub::Copilot::Types::ModelInfo;
use Moo;

has id                        => (is => 'ro', required => 1);
has name                      => (is => 'ro', required => 1);
has capabilities              => (is => 'ro', default => sub { {} });
has policy                    => (is => 'ro', default => sub { undef });
has billing                   => (is => 'ro', default => sub { undef });
has supportedReasoningEfforts => (is => 'ro', default => sub { undef });
has defaultReasoningEffort    => (is => 'ro', default => sub { undef });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        id                        => $hr->{id}           // '',
        name                      => $hr->{name}         // '',
        capabilities              => $hr->{capabilities}  // {},
        policy                    => $hr->{policy},
        billing                   => $hr->{billing},
        supportedReasoningEfforts => $hr->{supportedReasoningEfforts},
        defaultReasoningEffort    => $hr->{defaultReasoningEffort},
    );
}

sub TO_JSON {
    my ($self) = @_;
    my %h = (
        id           => $self->id,
        name         => $self->name,
        capabilities => $self->capabilities,
    );
    $h{policy}                    = $self->policy                    if defined $self->policy;
    $h{billing}                   = $self->billing                   if defined $self->billing;
    $h{supportedReasoningEfforts} = $self->supportedReasoningEfforts if defined $self->supportedReasoningEfforts;
    $h{defaultReasoningEffort}    = $self->defaultReasoningEffort    if defined $self->defaultReasoningEffort;
    return \%h;
}

# ============================================================================
# SessionMetadata
# ============================================================================
package GitHub::Copilot::Types::SessionMetadata;
use Moo;

has sessionId    => (is => 'ro', required => 1);
has startTime    => (is => 'ro', required => 1);
has modifiedTime => (is => 'ro', required => 1);
has isRemote     => (is => 'ro', default => sub { 0 });
has summary      => (is => 'ro', default => sub { undef });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        sessionId    => $hr->{sessionId}    // '',
        startTime    => $hr->{startTime}    // '',
        modifiedTime => $hr->{modifiedTime} // '',
        isRemote     => $hr->{isRemote}     // 0,
        summary      => $hr->{summary},
    );
}

sub TO_JSON {
    my ($self) = @_;
    my %h = (
        sessionId    => $self->sessionId,
        startTime    => $self->startTime,
        modifiedTime => $self->modifiedTime,
        isRemote     => $self->isRemote ? \1 : \0,
    );
    $h{summary} = $self->summary if defined $self->summary;
    return \%h;
}

# ============================================================================
# Tool - definition of a tool exposed to the CLI server
# ============================================================================
package GitHub::Copilot::Types::Tool;
use Moo;

has name        => (is => 'ro', required => 1);
has description => (is => 'ro', default => sub { '' });
has parameters  => (is => 'ro', default => sub { undef });
has handler     => (is => 'ro', required => 1);

sub to_wire {
    my ($self) = @_;
    my %h = (
        name        => $self->name,
        description => $self->description,
    );
    $h{parameters} = $self->parameters if defined $self->parameters;
    return \%h;
}

# ============================================================================
# ToolInvocation - context passed to tool handlers
# ============================================================================
package GitHub::Copilot::Types::ToolInvocation;
use Moo;

has sessionId  => (is => 'ro', required => 1);
has toolCallId => (is => 'ro', required => 1);
has toolName   => (is => 'ro', required => 1);
has arguments  => (is => 'ro', default => sub { undef });

sub from_hashref {
    my ($class, $hr) = @_;
    return $class->new(
        sessionId  => $hr->{sessionId}  // '',
        toolCallId => $hr->{toolCallId} // '',
        toolName   => $hr->{toolName}   // '',
        arguments  => $hr->{arguments},
    );
}

# ============================================================================
# ToolResultObject - structured tool result
# ============================================================================
package GitHub::Copilot::Types::ToolResultObject;
use Moo;

has textResultForLlm     => (is => 'ro', required => 1);
has resultType           => (is => 'ro', default => sub { 'success' });
has binaryResultsForLlm  => (is => 'ro', default => sub { undef });
has error                => (is => 'ro', default => sub { undef });
has sessionLog           => (is => 'ro', default => sub { undef });
has toolTelemetry        => (is => 'ro', default => sub { {} });

sub TO_JSON {
    my ($self) = @_;
    my %h = (
        textResultForLlm => $self->textResultForLlm,
        resultType       => $self->resultType,
    );
    $h{binaryResultsForLlm} = $self->binaryResultsForLlm if defined $self->binaryResultsForLlm;
    $h{error}               = $self->error                if defined $self->error;
    $h{sessionLog}          = $self->sessionLog           if defined $self->sessionLog;
    $h{toolTelemetry}       = $self->toolTelemetry        if defined $self->toolTelemetry;
    return \%h;
}

# ============================================================================
# MessageOptions
# ============================================================================
package GitHub::Copilot::Types::MessageOptions;
use Moo;

has prompt      => (is => 'ro', required => 1);
has attachments => (is => 'ro', default => sub { undef });
has mode        => (is => 'ro', default => sub { undef });

sub TO_JSON {
    my ($self) = @_;
    my %h = (prompt => $self->prompt);
    $h{attachments} = $self->attachments if defined $self->attachments;
    $h{mode}        = $self->mode        if defined $self->mode;
    return \%h;
}

# ============================================================================
# SessionConfig - configuration for creating a session
# ============================================================================
package GitHub::Copilot::Types::SessionConfig;
use Moo;

has session_id             => (is => 'ro', default => sub { undef });
has model                  => (is => 'ro', default => sub { undef });
has reasoning_effort       => (is => 'ro', default => sub { undef });
has tools                  => (is => 'ro', default => sub { [] });
has system_message         => (is => 'ro', default => sub { undef });
has available_tools        => (is => 'ro', default => sub { undef });
has excluded_tools         => (is => 'ro', default => sub { undef });
has provider               => (is => 'ro', default => sub { undef });
has on_permission_request  => (is => 'ro', default => sub { undef });
has on_user_input_request  => (is => 'ro', default => sub { undef });
has hooks                  => (is => 'ro', default => sub { undef });
has working_directory      => (is => 'ro', default => sub { undef });
has streaming              => (is => 'ro', default => sub { undef });
has mcp_servers            => (is => 'ro', default => sub { undef });
has custom_agents          => (is => 'ro', default => sub { undef });
has config_dir             => (is => 'ro', default => sub { undef });
has skill_directories      => (is => 'ro', default => sub { undef });
has disabled_skills        => (is => 'ro', default => sub { undef });
has infinite_sessions      => (is => 'ro', default => sub { undef });

sub to_wire {
    my ($self) = @_;
    my %payload;

    $payload{sessionId}       = $self->session_id       if defined $self->session_id;
    $payload{model}           = $self->model             if defined $self->model;
    $payload{reasoningEffort} = $self->reasoning_effort  if defined $self->reasoning_effort;

    if ($self->tools && @{ $self->tools }) {
        $payload{tools} = [ map { $_->to_wire } @{ $self->tools } ];
    }

    $payload{systemMessage}    = $self->system_message    if defined $self->system_message;
    $payload{availableTools}   = $self->available_tools   if defined $self->available_tools;
    $payload{excludedTools}    = $self->excluded_tools    if defined $self->excluded_tools;
    $payload{provider}         = $self->provider          if defined $self->provider;
    $payload{workingDirectory} = $self->working_directory if defined $self->working_directory;
    $payload{configDir}        = $self->config_dir        if defined $self->config_dir;
    $payload{mcpServers}       = $self->mcp_servers       if defined $self->mcp_servers;
    $payload{customAgents}     = $self->custom_agents     if defined $self->custom_agents;
    $payload{skillDirectories} = $self->skill_directories if defined $self->skill_directories;
    $payload{disabledSkills}   = $self->disabled_skills   if defined $self->disabled_skills;
    $payload{infiniteSessions} = $self->infinite_sessions if defined $self->infinite_sessions;

    $payload{requestPermission} = \1 if defined $self->on_permission_request;
    $payload{requestUserInput}  = \1 if defined $self->on_user_input_request;

    if (defined $self->hooks) {
        my $hooks = $self->hooks;
        my $has_hooks = 0;
        for my $key (keys %$hooks) {
            if (defined $hooks->{$key}) {
                $has_hooks = 1;
                last;
            }
        }
        $payload{hooks} = \1 if $has_hooks;
    }

    if (defined $self->streaming) {
        $payload{streaming} = $self->streaming ? \1 : \0;
    }

    return \%payload;
}

# ============================================================================
# SessionHooks - configuration for session hooks (hashref-based)
# ============================================================================
# Hooks are passed as a simple hashref with keys:
#   on_pre_tool_use         => sub { ... }
#   on_post_tool_use        => sub { ... }
#   on_user_prompt_submitted => sub { ... }
#   on_session_start        => sub { ... }
#   on_session_end          => sub { ... }
#   on_error_occurred       => sub { ... }
#
# The mapping to wire hookType strings is:
#   preToolUse           => on_pre_tool_use
#   postToolUse          => on_post_tool_use
#   userPromptSubmitted  => on_user_prompt_submitted
#   sessionStart         => on_session_start
#   sessionEnd           => on_session_end
#   errorOccurred        => on_error_occurred

1;

__END__

=head1 NAME

GitHub::Copilot::Types - Type definitions for the Copilot Perl SDK

=head1 SYNOPSIS

    use GitHub::Copilot::Types;

    my $event = GitHub::Copilot::Types::SessionEvent->new(
        type => 'assistant.message',
        data => { content => 'Hello!' },
    );

    my $tool = GitHub::Copilot::Types::Tool->new(
        name        => 'get_weather',
        description => 'Get weather for a city',
        parameters  => { type => 'object', properties => { city => { type => 'string' } } },
        handler     => sub { my ($args, $invocation) = @_; return "72F in $args->{city}"; },
    );

=head1 DESCRIPTION

This module defines all Moo-based data classes used by the Copilot Perl SDK,
mirroring the types used in the Node.js and Python SDKs.

=cut
