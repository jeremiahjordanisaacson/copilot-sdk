#!/usr/bin/env perl
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# basic_example.pl - Demonstrates basic usage of the GitHub Copilot Perl SDK
#
# Prerequisites:
#   1. Install the Copilot CLI (e.g., npm install -g @github/copilot)
#   2. Authenticate: copilot auth login
#   3. Install Perl dependencies:
#      cpanm Moo JSON::PP UUID::Tiny File::Which Thread::Queue
#
# Usage:
#   perl basic_example.pl
#   perl basic_example.pl --cli-path /path/to/copilot

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use GitHub::Copilot::Client;
use GitHub::Copilot::Types;
use GitHub::Copilot::DefineTool qw(define_tool);

# ---------------------------------------------------------------------------
# Parse command-line options
# ---------------------------------------------------------------------------

my $cli_path;
for my $i (0 .. $#ARGV) {
    if ($ARGV[$i] eq '--cli-path' && defined $ARGV[$i + 1]) {
        $cli_path = $ARGV[$i + 1];
    }
}

# ---------------------------------------------------------------------------
# Define a custom tool
# ---------------------------------------------------------------------------

my $weather_tool = define_tool(
    name        => 'get_weather',
    description => 'Get the current weather for a location',
    parameters  => {
        type       => 'object',
        properties => {
            location => {
                type        => 'string',
                description => 'City name or location',
            },
        },
        required => ['location'],
    },
    handler => sub {
        my ($args, $invocation) = @_;
        my $location = $args->{location} // 'unknown';
        # Simulated weather response
        return "Currently 72 degrees Fahrenheit and sunny in $location.";
    },
);

# ---------------------------------------------------------------------------
# Create client and session
# ---------------------------------------------------------------------------

my %client_args;
$client_args{cli_path} = $cli_path if defined $cli_path;

my $client = GitHub::Copilot::Client->new(%client_args);

print "Starting Copilot client...\n";
$client->start();
print "Connected! State: " . $client->get_state() . "\n";

# Ping the server
my $ping = $client->ping("hello from Perl");
print "Ping response: " . $ping->message . "\n";
print "Protocol version: " . ($ping->protocolVersion // 'N/A') . "\n";

# List available models
print "\nAvailable models:\n";
my $models = $client->list_models();
for my $model (@$models) {
    print "  - " . $model->id . " (" . $model->name . ")\n";
}

# Create a session with the custom tool
print "\nCreating session...\n";
my $session = $client->create_session(
    GitHub::Copilot::Types::SessionConfig->new(
        tools => [$weather_tool],
        on_permission_request => sub {
            my ($request, $context) = @_;
            print "[Permission] Approving: $request->{kind}\n";
            return { kind => 'approved' };
        },
    ),
);
print "Session created: " . $session->session_id . "\n";

# Subscribe to events
my $unsubscribe = $session->on(sub {
    my ($event) = @_;
    my $type = $event->type;

    if ($type eq 'assistant.message') {
        my $content = $event->data->{content} // '';
        print "\n[Assistant] $content\n";
    } elsif ($type eq 'assistant.message_delta') {
        # Streaming delta
        my $delta = $event->data->{deltaContent} // '';
        print $delta;
    } elsif ($type eq 'tool.executing') {
        my $tool_name = $event->data->{toolName} // 'unknown';
        print "[Tool] Executing: $tool_name\n";
    } elsif ($type eq 'session.idle') {
        print "[Session] Idle\n";
    } elsif ($type eq 'session.error') {
        my $msg = $event->data->{message} // 'unknown error';
        print "[Error] $msg\n";
    }
});

# ---------------------------------------------------------------------------
# Send a message and wait for the response
# ---------------------------------------------------------------------------

print "\nSending message: 'What is the weather in Seattle?'\n";
print "-" x 60 . "\n";

my $response = $session->send_and_wait(
    GitHub::Copilot::Types::MessageOptions->new(
        prompt => 'What is the weather in Seattle?',
    ),
    120,  # 120 second timeout
);

if ($response) {
    print "\n" . "=" x 60 . "\n";
    print "Final response type: " . $response->type . "\n";
    my $content = $response->data->{content} // '(no content)';
    print "Final content: $content\n";
} else {
    print "No assistant response received.\n";
}

# ---------------------------------------------------------------------------
# Send another message (no tool needed)
# ---------------------------------------------------------------------------

print "\n" . "-" x 60 . "\n";
print "Sending message: 'What is 2+2?'\n";
print "-" x 60 . "\n";

my $response2 = $session->send_and_wait(
    { prompt => 'What is 2+2? Reply with just the number.' },
    60,
);

if ($response2) {
    my $content = $response2->data->{content} // '(no content)';
    print "Answer: $content\n";
}

# ---------------------------------------------------------------------------
# Retrieve conversation history
# ---------------------------------------------------------------------------

print "\nConversation history:\n";
my $messages = $session->get_messages();
for my $event (@$messages) {
    my $type = $event->type;
    if ($type eq 'user.message') {
        print "  [User] " . ($event->data->{content} // '') . "\n";
    } elsif ($type eq 'assistant.message') {
        my $content = $event->data->{content} // '';
        my $preview = length($content) > 80 ? substr($content, 0, 80) . '...' : $content;
        print "  [Assistant] $preview\n";
    }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

print "\nCleaning up...\n";
$unsubscribe->();
$session->destroy();
my $errors = $client->stop();
if (@$errors) {
    print "Cleanup errors:\n";
    for my $e (@$errors) {
        print "  - $e\n";
    }
}
print "Done.\n";
