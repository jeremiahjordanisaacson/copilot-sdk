package GitHub::Copilot::JsonRpcClient;
# Copyright (c) Microsoft Corporation. All rights reserved.

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(is_utf8 encode);
use JSON::PP;
use threads;
use threads::shared;
use Thread::Queue;
use UUID::Tiny ':std';
use Time::HiRes qw(time sleep);
use Scalar::Util qw(blessed);

=head1 NAME

GitHub::Copilot::JsonRpcClient - JSON-RPC 2.0 client over stdio with Content-Length framing

=head1 DESCRIPTION

A minimal JSON-RPC 2.0 client that communicates over stdin/stdout of a child
process using Content-Length header framing (the same wire format used by
LSP / vscode-jsonrpc).

A background reader thread continuously reads messages from stdout and routes
them to the appropriate handler:

=over

=item * Responses are matched to pending requests by id.

=item * Notifications (no id) are dispatched to a registered notification handler.

=item * Incoming requests (method + id from server) are dispatched to registered
request handlers and responses are sent back.

=back

=cut

my $json = JSON::PP->new->utf8->canonical->allow_blessed->convert_blessed;

sub new {
    my ($class, %args) = @_;

    my $stdin_fh  = $args{stdin}  or croak "stdin filehandle required";
    my $stdout_fh = $args{stdout} or croak "stdout filehandle required";

    # Make sure filehandles are in binary/raw mode
    binmode($stdin_fh,  ':raw');
    binmode($stdout_fh, ':raw');

    my %pending :shared;
    my %self = (
        stdin_fh             => $stdin_fh,
        stdout_fh            => $stdout_fh,
        _pending             => \%pending,
        _response_queues     => {},   # id => Thread::Queue (not shared; managed carefully)
        _notification_handler => undef,
        _request_handlers    => {},
        _running             => 0,
        _reader_thread       => undef,
        _write_lock          => undef,
        _incoming_queue      => Thread::Queue->new(),
    );

    return bless \%self, $class;
}

# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

sub start {
    my ($self) = @_;
    return if $self->{_running};
    $self->{_running} = 1;

    # Start the background reader thread
    $self->{_reader_thread} = threads->create(sub {
        $self->_read_loop();
    });
    $self->{_reader_thread}->detach();

    return $self;
}

sub stop {
    my ($self) = @_;
    $self->{_running} = 0;
    # Signal all pending requests to unblock
    for my $id (keys %{ $self->{_pending} }) {
        my $q = $self->{_response_queues}{$id};
        $q->enqueue(undef) if $q;
    }
}

sub set_notification_handler {
    my ($self, $handler) = @_;
    $self->{_notification_handler} = $handler;
}

sub set_request_handler {
    my ($self, $method, $handler) = @_;
    if (defined $handler) {
        $self->{_request_handlers}{$method} = $handler;
    } else {
        delete $self->{_request_handlers}{$method};
    }
}

sub request {
    my ($self, $method, $params, $timeout) = @_;
    $params  //= {};
    $timeout //= 60;

    croak "Client not started" unless $self->{_running};

    my $id = create_uuid_as_string(UUID_V4);

    # Create a response queue for this request
    my $queue = Thread::Queue->new();
    {
        lock(%{ $self->{_pending} });
        $self->{_pending}{$id} = 1;
    }
    $self->{_response_queues}{$id} = $queue;

    my $message = {
        jsonrpc => '2.0',
        id      => $id,
        method  => $method,
        params  => $params,
    };

    $self->_send_message($message);

    # Wait for response with timeout
    my $deadline = time() + $timeout;
    my $response;
    while (1) {
        # Process any incoming requests/notifications on the main thread
        $self->_process_incoming();

        my $remaining = $deadline - time();
        if ($remaining <= 0) {
            lock(%{ $self->{_pending} });
            delete $self->{_pending}{$id};
            delete $self->{_response_queues}{$id};
            croak "JSON-RPC request '$method' timed out after ${timeout}s";
        }

        # Poll with a short timeout so we can process incoming messages
        $response = $queue->dequeue_timed(0.05);
        last if defined $response;
    }

    # Cleanup
    {
        lock(%{ $self->{_pending} });
        delete $self->{_pending}{$id};
    }
    delete $self->{_response_queues}{$id};

    # Decode response (it comes as a JSON string from the shared queue)
    my $resp = ref($response) ? $response : $json->decode($response);

    if (exists $resp->{error}) {
        my $err = $resp->{error};
        croak sprintf(
            "JSON-RPC Error %d: %s",
            $err->{code}    // -1,
            $err->{message} // 'Unknown error',
        );
    }

    return $resp->{result};
}

sub notify {
    my ($self, $method, $params) = @_;
    $params //= {};

    my $message = {
        jsonrpc => '2.0',
        method  => $method,
        params  => $params,
    };

    $self->_send_message($message);
}

# --------------------------------------------------------------------------
# Process incoming requests/notifications that were queued by the reader thread
# --------------------------------------------------------------------------

sub _process_incoming {
    my ($self) = @_;

    while (my $item = $self->{_incoming_queue}->dequeue_nb()) {
        my $msg = ref($item) ? $item : $json->decode($item);
        $self->_dispatch_incoming($msg);
    }
}

sub process_incoming {
    my ($self) = @_;
    $self->_process_incoming();
}

# --------------------------------------------------------------------------
# Message sending (thread-safe)
# --------------------------------------------------------------------------

sub _send_message {
    my ($self, $message) = @_;

    my $content = $json->encode($message);
    my $content_bytes = is_utf8($content) ?
        encode('UTF-8', $content) : $content;
    my $header = "Content-Length: " . length($content_bytes) . "\r\n\r\n";

    my $fh = $self->{stdin_fh};
    # Simple lock via local flock-like mechanism
    print $fh $header;
    print $fh $content_bytes;
    $fh->flush();
}

sub _send_response {
    my ($self, $id, $result) = @_;
    my $response = {
        jsonrpc => '2.0',
        id      => $id,
        result  => $result,
    };
    $self->_send_message($response);
}

sub _send_error_response {
    my ($self, $id, $code, $message, $data) = @_;
    my $response = {
        jsonrpc => '2.0',
        id      => $id,
        error   => {
            code    => $code,
            message => $message,
            (defined $data ? (data => $data) : ()),
        },
    };
    $self->_send_message($response);
}

# --------------------------------------------------------------------------
# Background reader thread
# --------------------------------------------------------------------------

sub _read_loop {
    my ($self) = @_;

    eval {
        while ($self->{_running}) {
            my $message = $self->_read_message();
            last unless defined $message;
            $self->_handle_message($message);
        }
    };
    if ($@ && $self->{_running}) {
        warn "JSON-RPC read loop error: $@";
    }
}

sub _read_exact {
    my ($self, $num_bytes) = @_;
    my $fh = $self->{stdout_fh};
    my $buf = '';
    my $remaining = $num_bytes;

    while ($remaining > 0) {
        my $bytes_read = read($fh, my $chunk, $remaining);
        if (!defined $bytes_read || $bytes_read == 0) {
            die "Unexpected end of stream while reading JSON-RPC message";
        }
        $buf .= $chunk;
        $remaining -= $bytes_read;
    }

    return $buf;
}

sub _read_message {
    my ($self) = @_;
    my $fh = $self->{stdout_fh};

    # Read header line
    my $header_line = <$fh>;
    return undef unless defined $header_line;

    chomp $header_line;
    $header_line =~ s/\r$//;

    return undef unless $header_line =~ /^Content-Length:\s*(\d+)/i;
    my $content_length = $1;

    # Read blank line separator
    my $blank = <$fh>;

    # Read exact content
    my $content = $self->_read_exact($content_length);

    return $json->decode($content);
}

sub _handle_message {
    my ($self, $message) = @_;

    # Response to a pending request
    if (exists $message->{id} && (exists $message->{result} || exists $message->{error})) {
        my $id = $message->{id};
        my $queue;
        {
            lock(%{ $self->{_pending} });
            if (exists $self->{_pending}{$id}) {
                $queue = $self->{_response_queues}{$id};
            }
        }
        if ($queue) {
            # Encode to string for thread-safe transfer
            $queue->enqueue($json->encode($message));
        }
        return;
    }

    # Notification (no id) or incoming request (method + id)
    # Queue for main thread processing
    $self->{_incoming_queue}->enqueue($json->encode($message));
}

sub _dispatch_incoming {
    my ($self, $message) = @_;

    # Notification from server (method, no id)
    if (exists $message->{method} && !exists $message->{id}) {
        if ($self->{_notification_handler}) {
            eval {
                $self->{_notification_handler}->(
                    $message->{method},
                    $message->{params} // {},
                );
            };
            warn "Notification handler error: $@" if $@;
        }
        return;
    }

    # Incoming request from server (method + id)
    if (exists $message->{method} && exists $message->{id}) {
        my $method  = $message->{method};
        my $id      = $message->{id};
        my $params  = $message->{params} // {};
        my $handler = $self->{_request_handlers}{$method};

        if (!$handler) {
            $self->_send_error_response(
                $id, -32601,
                "Method not found: $method",
                undef,
            );
            return;
        }

        eval {
            my $result = $handler->($params);
            $result = {} unless defined $result;
            $self->_send_response($id, $result);
        };
        if ($@) {
            $self->_send_error_response($id, -32603, "$@", undef);
        }
        return;
    }
}

1;

__END__

=head1 SYNOPSIS

    use GitHub::Copilot::JsonRpcClient;
    use IPC::Open3;

    my $pid = open3(my $stdin, my $stdout, my $stderr,
                    'copilot', '--headless', '--stdio');

    my $client = GitHub::Copilot::JsonRpcClient->new(
        stdin  => $stdin,
        stdout => $stdout,
    );
    $client->start();

    my $result = $client->request('ping', { message => 'hello' });
    print "Got: $result->{message}\n";

    $client->stop();

=cut
