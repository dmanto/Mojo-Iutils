package Mojo::Iutils::Server;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Scalar::Util 'weaken';
use Mojo::Util qw/steady_time/;
use Mojo::File;
use Mojo::IOLoop;
use Time::HiRes qw/sleep time/;

has 'port';
has 'broker_id';

# minimallist broker server
# Protocol definition:
#
# client --> server
#
# <destination1>[:<destination2...:destinationN]<space char><command char>[<content>]<EOR char>
#
#   destination:  is the id number of the targetted remote client connection, as known by the server.
#                 : char separates id numbers when more than one targeted client is needed
#                 0 means all connected clients
#
#   space char:   space (0x20) char
#
#   command char: 'S' (0x53 char) means Interprocess sincronization command. Client corresponding
#                 to destination will need to syncronize against local events table
#                 '@' (0x40 char) means rename command. Client corresponding
#                 to destination will be known with the number indicated in <content>
#
# server --> client
#
# <command char><EOR char>
#
# where:
#
#   command char: 'S' (0x53 char) means Interprocess sincronization command. Client
#                 receiving this command will syncronize against local events table
#                 'A' (0x41 char) means rename acknowledged command. Client receiving
#                 this command will consider itself as connected
#

sub read_ievents { croak 'Method "read_ievents" not implemented by parent' }

sub start {
    my $self = shift;
    weaken $self;
    $self->{_conns}     = {};
    $self->{_server_id} = Mojo::IOLoop->server(
        { address => '127.0.0.1' } => sub {    # some client connects
            my ( $loop, $stream, $id ) = @_;

            # no timeouts
            $stream->timeout(0);

     # remote port as unique reference until rename (i.e. rename will change it)
            my $origin = -$stream->handle->peerport;
            $self->{_conns}{$origin} = $stream;

            # weaken $self->{_conns}{$origin};

            # say STDERR "Server en $$, conexion desde $origin";
            my $pndg = '';
            $stream->on(
                read => sub {
                    my ( $stream, $bytes ) = @_;
                    return unless defined $bytes;
                    my @msgs = split /\n/, $pndg . $bytes,
                      -1;    # keep last separator
                    $pndg = pop @msgs // '';
                    for my $msg (@msgs) {
                        next unless $msg && $msg =~ /(\S+)\s(\S)(.*)/;
                        my ( $d, $cmd, $content ) = ( $1, $2, $3 );
                        if ( $cmd eq 'S' ) {    # sync ievents command
                            $self->sync_remotes( $origin, $d );
                        }
                        elsif ( $cmd eq '@' ) {    # rename cmd
                            $self->{_conns}{$content} =
                              $self->{_conns}{$origin};
                            delete $self->{_conns}{$origin};
                            $origin = $content;
                            $stream->write("A\n");    # acknowledges rename
                            next;
                        }    # besides that, ignore commands
                    }
                }
            );
            $stream->on(
                close => sub {
                    delete $self->{_conns}{$origin};
                }
            );
            $stream->on(
                error => sub {
                    delete $self->{_conns}{$origin}
                      ;      # client is who acts on errors
                }
            );
        }
    );

    $self->port( Mojo::IOLoop->acceptor( $self->{_server_id} )->port );
    return $self;
}

sub sync_remotes {
    my ( $self, $orig, $dst ) = @_;

    # $dst false (0) means all clients
    my @dests =
      $dst
      ? split /:/, $dst
      : keys %{ $self->{_conns} };

    # include own client in broadcast case
    push @dests, $self->{broker_id} unless $dst;

    # say STDERR $ddd;
    for my $dp (@dests) {
        next if $dp eq $orig;    # ignore syncs to requester
        $self->read_ievents && next
          if $dp eq $self->{broker_id};    # dest is own client
        next
          unless $self->{_conns}{$dp};     # ignore not connected

        # say STDERR "server enviara SYNC command";
        $self->{_conns}{$dp}->write("S\n");
    }
}

sub _cleanup {
    my $self = shift;
    say "Llama server DESTROY";
    $self->{_conns}{$_} && $self->{_conns}{$_}->DESTROY
      for keys %{ $self->{_conns} };       # server stops
    Mojo::IOLoop->acceptor( $self->{_server_id} )->DESTROY
      if $self->{_server_id};
}

sub DESTROY {
    Mojo::Util::_global_destruction() or shift->_cleanup;
}

1;

=encoding utf8

=head1 NAME

Mojo::Iutils::Minibroker::Server - Minibroker back end

=head1 SYNOPSYS

    use Mojo::Iutils::Minibroker::Server

=head1 DESCRIPTION

L<Mojo::Iutils::Minibroker::Server> is the backend to connect to the L<Mojo::Iutils::Minibroker> ad-hoc
broker (almost serverless broker)

=head1 ATTRIBUTES

L<Mojo::Iutils::Minibroker::Server> inherits all attributes from L<Mojo::EventEmitter> and implements
the following ones:

=head1 METHODS

L<Mojo::Iutils::Minibroker::Server> inherits all methods from L<Mojo::EventEmitter> and implements
the following ones:

=head2 new

  my $srv = Mojo::Iutils::Minibroker::Server->new;

Construct a new L<Mojo::Iutils::Minibroker::Server> object.

=head2 start

  $srv->start;

Used to get Minibroker server running



=head1 AUTHOR

Daniel Mantovani <dmanto@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2019 by Daniel Mantovani.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 SEE ALSO

L<Mojolicious>, L<Mojo::Iutils>, L<Mojo::Iutils::Client>

=cut

