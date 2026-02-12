package GitHub::Copilot::DefineTool;
# Copyright (c) Microsoft Corporation. All rights reserved.

use strict;
use warnings;
use Exporter 'import';
use Carp qw(croak);
use JSON::PP;

use GitHub::Copilot::Types;

our @EXPORT_OK = qw(define_tool);

=head1 NAME

GitHub::Copilot::DefineTool - Helper for defining tools for the Copilot SDK

=head1 SYNOPSIS

    use GitHub::Copilot::DefineTool qw(define_tool);

    # Simple tool with inline handler
    my $tool = define_tool(
        name        => 'get_weather',
        description => 'Get the weather for a city',
        parameters  => {
            type       => 'object',
            properties => {
                city => { type => 'string', description => 'City name' },
            },
            required => ['city'],
        },
        handler => sub {
            my ($args, $invocation) = @_;
            return "72F and sunny in $args->{city}";
        },
    );

    # Tool returning a structured ToolResultObject
    my $tool2 = define_tool(
        name        => 'search_issues',
        description => 'Search GitHub issues',
        parameters  => {
            type       => 'object',
            properties => {
                query => { type => 'string', description => 'Search query' },
            },
            required => ['query'],
        },
        handler => sub {
            my ($args, $invocation) = @_;
            my @results = do_search($args->{query});
            return GitHub::Copilot::Types::ToolResultObject->new(
                textResultForLlm => encode_json(\@results),
                resultType       => 'success',
            );
        },
    );

=head1 DESCRIPTION

Provides a convenient C<define_tool()> function to create
C<GitHub::Copilot::Types::Tool> objects with proper validation.

The handler receives two arguments:

=over

=item C<$args> - The parsed arguments hashref from the tool invocation

=item C<$invocation> - A C<GitHub::Copilot::Types::ToolInvocation> object
with sessionId, toolCallId, toolName, and arguments

=back

The handler can return:

=over

=item A plain string (wrapped as a success result)

=item A hashref (JSON-encoded as a success result)

=item A C<GitHub::Copilot::Types::ToolResultObject> (passed through)

=item C<undef> (treated as failure)

=back

=cut

sub define_tool {
    my (%args) = @_;

    my $name        = $args{name}        // croak "name is required";
    my $handler     = $args{handler}     // croak "handler is required";
    my $description = $args{description} // '';
    my $parameters  = $args{parameters};

    croak "handler must be a code reference" unless ref($handler) eq 'CODE';

    return GitHub::Copilot::Types::Tool->new(
        name        => $name,
        description => $description,
        parameters  => $parameters,
        handler     => $handler,
    );
}

1;

__END__

=head1 FUNCTIONS

=head2 define_tool(%args)

Creates and returns a C<GitHub::Copilot::Types::Tool> object.

Required arguments:

    name    => 'tool_name'
    handler => sub { my ($args, $invocation) = @_; ... }

Optional arguments:

    description => 'What this tool does'
    parameters  => { type => 'object', properties => { ... } }

=cut
