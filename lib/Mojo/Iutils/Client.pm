package Mojo::Iutils::Client;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Time::HiRes qw/time sleep/;
use Scalar::Util 'weaken';
use Mojo::File;
use Mojo::IOLoop;

has 'port';
has 'broker_id';
has 'connected';

sub read_ievents { croak 'Method "read_ievents" not implemented by parent' }

sub connect {
    my ( $self, $port ) = @_;
    weaken $self;
    return $self if $self->connected;    # no reconnections allowed
    $port //= $self->port;
    return $self
      unless $self->broker_id && $port;    # nothing to do if dont have those
    $self->{id} = Mojo::IOLoop->client(
        { address => '127.0.0.1', port => $self->port, timeout => 2 } => sub {
            my ( $loop, $err, $stream ) = @_;
            if ($stream) {
                my $pndg = '';             # pending data
                $stream->timeout(0);       # permanent
                $stream->on(
                    read => sub {
                        my ( $stream, $bytes ) = @_;
                        return unless defined $bytes;
                        my @msgs = split /\n/, $pndg . $bytes,
                          -1;              # keep last separator
                        $pndg = pop @msgs // '';
                        for my $msg (@msgs) {
                            next unless $msg && $msg =~ /(\w)/;
                            my $cmd = $1;
                            if ( $cmd eq 'S' ) {
                                $self->read_ievents;
                            }
                            elsif ( $cmd eq 'A' ) {    # name acknowledged
                                $self->connected(1);
                            }
                        }
                    }
                );
                $stream->on(
                    close => sub {

                        # say STDERR "stream closed";
                        $self->connected(0);
                        delete $self->{_stream};
                    }
                );
                $stream->on(
                    error => sub {

                        # say STDERR "stream error";
                        $self->connected(0);
                        delete $self->{_stream};
                    }
                );

                # first thing to do is ask to be renamed at server side
                my $name = $self->broker_id;
                $stream->write("0 \@$name\n");
                my $aux_stream = $stream;
                $self->{_stream} = $aux_stream;    # for interprocess emits
                weaken( $self->{_stream} );
            }
        }
    );

    return $self;
}

sub sync_remotes {
    my ( $self, $orig, $dst ) = @_;
    $self->{_stream}->write("$dst S\n");
}

sub _cleanup {
    my $self = shift;
    $self->{_stream}->close if $self->{_stream};
}

sub DESTROY {
    Mojo::Util::_global_destruction() or shift->_cleanup;
}

1;
__END__

=encoding utf8

=head1 NAME

Mojo::Iutils::Minibroker::Client - Minibroker front end

=head1 SYNOPSYS

    use Mojo::Iutils::Minibroker::Client

=head1 DESCRIPTION

L<Mojo::Iutils::Minibroker::Client> is the frontend to connect to the L<Mojo::Iutils::Minibroker> ad-hoc
broker (almost serverless broker)

=head1 ATTRIBUTES

L<Mojo::Iutils::Minibroker::Client> inherits all attributes from L<Mojo::EventEmitter> and implements
the following ones:

=head2 sqlite

    my $sqlite = $client->sqlite;
    $client    = $client->sqlite(Mojo::SQLite->new);

L<Mojo::SQLite> object used to sync processes, and to store all data.

=head1 METHODS

L<Mojo::Iutils::Minibroker::Client> inherits all methods from L<Mojo::EventEmitter> and implements
the following ones:

=head2 connect

  $cl->connect;

Used to connect to the Minibroker server

=head2 get_broker_port

  my $port = $cl->get_broker_port;

Used to get Minibroker server port (local port)

=head2 iemit

  $cl->iemit(event => @args);

Used to emit an interprocess event

=head2 unique

  my $u = $cl->unique;

Used to get an intersystem unique event name

=head2 new

Construct a new L<Mojo::Iutils::Minibroker::Client> object.

=head1 AUTHOR

Daniel Mantovani <dmanto@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2019 by Daniel Mantovani.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 SEE ALSO

L<Mojolicious>, L<Mojo::SQLite>

=cut
