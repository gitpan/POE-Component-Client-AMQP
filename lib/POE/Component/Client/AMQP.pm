package POE::Component::Client::AMQP;

=head1 NAME

POE::Component::Client::AMQP - Asynchronous AMQP client implementation in POE

=head1 SYNOPSIS

  use POE::Component::Client::AMQP;

  Net::AMQP::Protocol->load_xml_spec('amqp0-8.xml');

  my $amq = Component::Client::AMQP->create(
      RemoteAddress => 'mq.domain.tld',
  );

  $amq->channel(1)->queue('frank')->subscribe(sub {
      my ($payload, $meta) = @_;

      my $reply_to = $meta->{header_frame}->reply_to;

      $amq->channel(1)->queue($reply_to)->publish("Message received");
  });

  $amq->run();

=head1 DESCRIPTION 

This module implements the Advanced Message Queue Protocol (AMQP) TCP/IP client.  It's goal is to provide users with a quick and easy way of using AMQP while at the same time exposing the advanced functionality of the protocol if needed.

The (de)serialization and representation logic is handled by L<Net::AMQP>, which needs to be setup (via load_xml_spec()) prior to this client software running.  Please see the docs there for further information on this.

=cut

use strict;
use warnings;
use POE qw(
    Filter::Stream
    Component::Client::TCP
    Component::Client::AMQP::Channel
    Component::Client::AMQP::Queue
);
use Params::Validate qw(validate_with);
use Net::AMQP;
use Net::AMQP::Common qw(:all);
use Carp;

use base qw(Class::Accessor);
__PACKAGE__->mk_accessors(qw(Logger is_stopped is_started is_stopping));

our $VERSION = 0.01;

=head1 USAGE

=head2 create (...)

=over 4

Create a new AMQP client.  Arguments to this method:

=over 4

=item I<RemoteAddress> (default: 127.0.0.1)

Connect to this host

=item I<RemotePort> (default: 5672)

=item I<Username> (default: guest)

=item I<Password> (default: guest)

=item I<VirtualHost> (default: /)

=item I<Logger> (default: simple screen logger)

Provide an object which implements 'debug', 'info' and 'error' logging methods (such as L<Log::Log4perl>).

=item I<Debug>

This module provides extensive debugging options.  These are specified as a hash as follows:

=over 4

=item I<logic> (boolean)

Display decisions the code is making

=item I<frame_input> (boolean)

=item I<frame_output> (boolean)

Use the I<frame_dumper> code to display frames that come in from or out to the server.

=item I<frame_dumper> (coderef)

A coderef which, given a L<Net::AMQP::Frame> object, will return a string representation of it, prefixed with "\n".

=item I<raw_input> (boolean)

=item I<raw_output> (boolean)

Use the I<raw_dumper> code to display raw data that comes in from or out to the server.

=item I<raw_dumper> (coderef)

A coderef which, given a raw string, will return a byte representation of it, prefixed with "\n".

=back

=item I<Alias> (default: amqp_client)

The POE session alias of the main client session

=item I<AliasTCP> (default: tcp_client)

The POE session alias of the TCP client

=item I<Callbacks> (default: {})

Provide callbacks.  At the moment, 'Startup' is the only recognized callback.

=item I<is_testing>

Set to '1' to avoid creating POE::Sessions (mainly useful in t/ scripts)

=back

Returns a class object.

=back

=cut

sub create {
    my $class = shift;

    my %self = validate_with(
        params => \@_,
        spec => {
            RemoteAddress => { default => '127.0.0.1' },
            RemotePort    => { default => 5672 },
            Username      => { default => 'guest' },
            Password      => { default => 'guest' },
            VirtualHost   => { default => '/' },

            Logger        => 0,
            Debug         => { default => {} },

            Alias         => { default => 'amqp_client' },
            AliasTCP      => { default => 'tcp_client' },
            Callbacks     => { default => {} },

            channels      => { default => {} },
            is_started    => { default => 0 },
            is_testing    => { default => 0 },
        },
        allow_extra => 1,
    );

    $self{Logger} ||= POE::Component::Client::AMQP::FakeLogger->new(
        debug => keys(%{ $self{Debug} }) ? 1 : 0,
    );

    my $self = bless \%self, $class;

    my %Debug = validate_with(
        params => $self->{Debug},
        spec => {
            raw_input   => 0,
            raw_output  => 0,
            raw_dumper => { default => sub {
                my $output = shift;
                return "\nraw [".length($output)."]: ".show_ascii($output);
            } },

            frame_input => 0,
            frame_output => 0,
            frame_dumper => { default => sub {} },

            logic => 0,
        },
    );
    $self->{Debug} = \%Debug;

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                server_send
                server_connected
                server_disconnect
            )],
        ],
    ) unless $self->{is_testing};

    POE::Component::Client::TCP->new(
        Alias         => $self->{AliasTCP},
        RemoteAddress => $self->{RemoteAddress},
        RemotePort    => $self->{RemotePort},
        Connected     => sub { $self->tcp_connected(@_) },
        Disconnected  => sub { $self->Logger->info("TCP connection is disconnected") },
        ServerInput   => sub { $self->tcp_server_input(@_) },
        Filter        => 'POE::Filter::Stream',
    ) unless $self->{is_testing};

    return $self;
}

## Public Class Methods ###

=head1 CLASS METHODS

=head2 do_when_startup (...)

=over 4

Pass a subref that should be executed after the client has connected and authenticated with the remote AMQP server.  If the client is already connected and authenticated, the subref will be called immediately.  Think: deferred.

=back

=cut

sub do_when_startup {
    my ($self, $subref) = @_;

    if ($self->{is_started}) {
        $subref->();
    }
    else {
        push @{ $self->{Callbacks}{Startup} }, $subref;
    }
}

=head2 channel ($id)

=over 4

Call with an optional argument $id (1 - 65536).  Returns a L<POE::Component::Client::AMQP::Channel> object which can be used immediately.

=back

=cut

sub channel {
    my ($self, $id) = @_;

    if (defined $id && $self->{channels}{$id}) {
        return $self->{channels}{$id};
    }

    my $channel = POE::Component::Client::AMQP::Channel->create(
        id => $id,
        server => $self,
    );

    # We don't need to record the channel, as the Channel->create() did so already in our 'channels' hash

    return $channel;
}

=head2 run ()

=over 4

Shortcut to calling $poe_kernel->run

=back

=cut

sub run {
    $poe_kernel->run();
}

=head2 stop ()

=over 4

Shortcut to calling the POE state 'disconnect'

=back

=cut

sub stop {
    my $self = shift;
    $poe_kernel->call($self->{Alias}, 'server_disconnect');
}

=head1 POE STATES

The following are states you can post to to interact with the client.  Use the alias defined in the C<create()> call above.

=cut

sub _start {
    my ($self, $kernel) = @_[OBJECT, KERNEL];

    $kernel->alias_set($self->{Alias});
}

=head2 server_disconnect

=over 4

Send a Connection.Close request

=back

=cut

sub server_disconnect {
    my ($self, $kernel) = @_[OBJECT, KERNEL];

    $self->{is_stopping} = 1;

    $kernel->yield(server_send =>
        Net::AMQP::Frame::Method->new(
            synchronous_callback => sub {
                $self->{is_stopped} = 1;
                $self->{is_started} = 0;
            },
            method_frame => Net::AMQP::Protocol::Connection::Close->new(),
        )
    );
}

sub server_connected {
    my ($self, $kernel) = @_[OBJECT, KERNEL];

    $self->{Logger}->info("Connected to the AMQP server and ready to act");

    # Call the callbacks if present
    if ($self->{Callbacks}{Startup}) {
        foreach my $subref (@{ $self->{Callbacks}{Startup} }) {
            $subref->();
        }
    }

    $self->{is_started} = 1;
}

=head2 server_send (@output)

=over 4

Pass one or more L<Net::AMQP::Frame> objects.  For short hand, you may pass L<Net::AMQP::Protocol::Base> objects, which will be automatically wrapped in the appropriate frame type, with channel 0.  These frames will be written to the server.  In the case of L<Net::AMQP::Frame::Method> objects which are calling a synchronous method, the client will handle them one at a time, waiting until a synchronous method returns properly before sending further synchronous frames.  This happens automatically.

=back

=cut

sub server_send {
    my ($self, $kernel, @output) = @_[OBJECT, KERNEL, ARG0 .. $#_];

    while (my $output = shift @output) {
        if (! defined $output || ! ref $output) {
            $self->{Logger}->error("Server send called with invalid output (".(defined $output ? $output : 'undef').")");
            next;
        }

        if ($output->isa("Net::AMQP::Protocol::Base")) {
            $output = $output->frame_wrap;
        }

        if (! $output->isa("Net::AMQP::Frame")) {
            $self->{Logger}->error("Server send called with invalid output (".ref($output).")");
            next;
        }

        # Set default channel
        $output->channel(0) unless defined $output->channel;

        if ($output->isa('Net::AMQP::Frame::Method') && $output->method_frame->method_spec->{synchronous}) {
            # If we're calling a synchronous method, then the server won't send any other
            # synchronous replies of particular type(s) until this message is replied to.
            # Wait for replies of these type(s) and don't send other messages until they're
            # cleared.

            my $output_class = ref($output->method_frame);

            # FIXME: It appears that RabbitMQ won't let us do two disimilar synchronous requests at once
            if (my @waiting_classes = keys %{ $self->{wait_synchronous} }) {
                $self->{Logger}->debug("Class $waiting_classes[0] is already waiting; do nothing else until it's complete; defering")
                    if $self->{Debug}{logic};
                push @{ $self->{wait_synchronous}{$waiting_classes[0]}{process_after} }, [ $output, @output ];
                return;
            }

            if ($self->{wait_synchronous}{$output_class}) {
                # There are already other things waiting; enqueue this output
                $self->{Logger}->debug("Class $output_class is already synchronously waiting; defering this and subsequent output")
                    if $self->{Debug}{logic};
                push @{ $self->{wait_synchronous}{$output_class}{process_after} }, [ $output, @output ];
                return;
            }

            my $responses = $output_class->method_spec->{responses};

            if (keys %$responses) {
                $self->{Logger}->debug("Setting up synchronous callback for $output_class")
                    if $self->{Debug}{logic};
                $self->{wait_synchronous}{$output_class} = {
                    request  => $output,
                    responses => $responses,
                    process_after => [],
                };
            }
        }

        my $raw_output = $output->to_raw_frame();
        $self->{Logger}->debug(
            'chan(' . $output->channel . ") >>> ".$output->type_string
            . ($self->{Debug}{frame_output} ? $self->{Debug}{frame_dumper}($output) : '')
            . ($self->{Debug}{raw_output} ? $self->{Debug}{raw_dumper}($raw_output) : '')
        );
        $output = $raw_output;

        $self->{HeapTCP}{server}->put($output);
    }
}

## Private Class Methods ###

sub tcp_connected {
    my $self = shift;
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    $self->{Logger}->debug("Connected to remote host");

    #$self->{Logger}->debug("Sending 4.2.2 Protocol Header");
    $heap->{server}->put( Net::AMQP::Protocol->header );

    $self->{HeapTCP} = $heap;
}

sub tcp_server_input {
    my $self = shift;
    my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

    $self->{Logger}->debug("Server said: " . $self->{Debug}{raw_dumper}($input))
        if $self->{Debug}{raw_input};

    my @frames = Net::AMQP->parse_raw_frames(\$input);
    FRAMES:
    foreach my $frame (@frames) {
        $self->{Logger}->debug(
            'chan(' . $frame->channel . ") <<< ".$frame->type_string
            . ($self->{Debug}{frame_input} ? $self->{Debug}{frame_dumper}($frame) : '')
        );

        if ($frame->isa('Net::AMQP::Frame::Method')) {
            my $method_frame = $frame->method_frame;

            # Check the 'wait_synchronous' hash to see if this response is a synchronous reply
            my $method_frame_class = ref $method_frame;
            if ($method_frame_class->method_spec->{synchronous}) {
                $self->{Logger}->debug("Checking 'wait_synchronous' hash against $method_frame_class") if $self->{Debug}{logic};

                my $matching_output_class;
                while (my ($output_class, $details) = each %{ $self->{wait_synchronous} }) {
                    next unless $details->{responses}{ $method_frame_class };
                    $matching_output_class = $output_class;
                    last;
                }

                if ($matching_output_class) {
                    $self->{Logger}->debug("Response type '$method_frame_class' found from waiting request '$matching_output_class'")
                        if $self->{Debug}{logic};

                    my $details = delete $self->{wait_synchronous}{$matching_output_class};

                    # Call the asynch callback if there is one
                    if (my $callback = delete $details->{request}{synchronous_callback}) {
                        $self->{Logger}->debug("Calling $matching_output_class callback") if $self->{Debug}{logic};
                        $callback->($frame);
                    }

                    # Dequeue anything that was blocked by this
                    foreach my $output (@{ $details->{process_after} }) {
                        $self->{Logger}->debug("Dequeueing items that blocked due to '$method_frame_class'") if $self->{Debug}{logic};
                        $kernel->post($self->{Alias}, server_send => @$output);
                    }

                    # Consider this frame handled
                    next FRAMES;
                }
            }

            # Act upon connection-level methods
            if ($frame->channel == 0) {
                if ($method_frame->isa('Net::AMQP::Protocol::Connection::Start')) {
                    $kernel->post($self->{Alias}, server_send =>
                        Net::AMQP::Protocol::Connection::StartOk->new(
                            client_properties => {
                                platform    => 'Perl/POE',
                                product     => __PACKAGE__,
                                information => 'http://code.xmission.com/',
                                version     => $VERSION,
                            },
                            mechanism => 'AMQPLAIN', # TODO - ensure this is in $method_frame{mechanisms}
                            response => { LOGIN => $self->{Username}, PASSWORD => $self->{Password} },
                            locale => 'en_US',
                        ),
                    );
                    next FRAMES;
                }
                elsif ($method_frame->isa('Net::AMQP::Protocol::Connection::Tune')) {
                    $kernel->post($self->{Alias}, server_send =>
                        Net::AMQP::Protocol::Connection::TuneOk->new(
                            channel_max => 0,
                            frame_max => 131072,
                            heartbeat => 0,
                        ),
                        Net::AMQP::Frame::Method->new(
                            synchronous_callback => sub {
                                $kernel->post($self->{Alias}, 'server_connected');
                            },
                            method_frame => Net::AMQP::Protocol::Connection::Open->new(
                                virtual_host => $self->{VirtualHost},
                                capabilities => '',
                                insist => 1,
                            ),
                        ),
                    );
                    next FRAMES;
                }
            }
        }

        if ($frame->channel != 0) {
            my $channel = $self->{channels}{ $frame->channel };
            if (! $channel) {
                $self->{Logger}->error("Received frame on channel ".$frame->channel." which we didn't request the creation of");
                next FRAMES;
            }
            $kernel->post($channel->{Alias}, server_input => $frame);
        }
        else {
            $self->{Logger}->error("Unhandled input frame ".ref($frame));
        }
    }
}

{
    package POE::Component::Client::AMQP::FakeLogger;

    use strict;
    use warnings;

    sub new {
        my ($class, %self) = @_;
        return bless \%self, $class;
    }

    sub info  { shift->log_it('INFO', @_) }
    sub error { shift->log_it('ERROR', @_) }
    sub debug { shift->log_it('DEBUG', @_) }

    sub log_it {
        my ($self, $method, $message) = @_;
        return if $method eq 'DEBUG' && ! $self->{debug};
        chomp $message;
        print '[' . localtime(time) ."] $method: $message\n";
    }
}

=head1 SEE ALSO

L<POE>, L<Net::AMQP>

=head1 COPYRIGHT

Copyright (c) 2009 Eric Waters and XMission LLC (http://www.xmission.com/).  All rights reserved.  This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included with this module.

=head1 AUTHOR

Eric Waters <ewaters@gmail.com>

=cut

1;
