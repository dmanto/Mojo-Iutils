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
has
  parent_instance =>
  sub { Carp::confess('parent_instance is required in constructor') },
  weak => 1;
has connection_timeout => sub { 2 };
has rename_timeout     => sub { shift->connection_timeout + 1 };

sub read_ievents { croak 'Method "read_ievents" not implemented by parent' }

sub connect {
    my $self = shift;
    $self->{_connection_timeout_id} = Mojo::IOLoop->timer(
        $self->rename_timeout => sub {
            Mojo::IOLoop->remove( delete $self->{_connection_timeout_id} );
            $self->emit('rename_timeout');
        }
    );
    $self->{_client} = Mojo::IOLoop->client(
        {
            address => '127.0.0.1',
            port    => $self->port,
            timeout => $self->connection_timeout
        } => sub {
            my ( $loop, $err, $stream ) = @_;
            if ($stream) {
                my $pndg = '';          # pending data
                $stream->timeout(0);    # permanent
                $stream->on(
                    read => sub {
                        my ( $stream, $bytes ) = @_;
                        return unless defined $bytes;
                        my @msgs = split /\n/, $pndg . $bytes,
                          -1;           # keep last separator
                        $pndg = pop @msgs // '';
                        for my $msg (@msgs) {
                            next unless $msg && $msg =~ /(\w)/;
                            my $cmd = $1;
                            if ( $cmd eq 'S' ) {
                                $self->read_ievents;
                            }
                            elsif ( $cmd eq 'A' ) {    # name acknowledged
                                $self->connected(1);
                                Mojo::IOLoop->remove(
                                    delete $self->{_connection_timeout_id} );
                            }
                        }
                    }
                );
                $stream->on(
                    close => sub {

                        delete $self->{_stream};
                        if ( $self->connected ) {
                            $self->connected(0);
                            $self->emit('disconnected');
                        }
                    }
                );
                $stream->on(
                    error => sub {
                        delete $self->{_stream};
                        if ( $self->connected ) {
                            $self->connected(0);
                            $self->emit('disconnected');
                        }
                    }
                );

                # first thing to do is ask to be renamed at server side
                my $name = $self->broker_id;
                $stream->write("0 \@$name\n");
                my $aux_stream = $stream;
                $self->{_stream} = $aux_stream;    # for interprocess emits
                weaken( $self->{_stream} );
            }
            else {
                Mojo::IOLoop->remove( delete $self->{_connection_timeout_id} );
                $self->emit('connection_timeout');
            }
        }
    );
    weaken $self;
    return $self;
}

sub sync_remotes {
    my ( $self, $orig, $dst ) = @_;
    $self->{_stream}->write("$dst S\n");
}

sub _cleanup {
    my $self = shift;
    $self->connected(0);    # no disconnected events on destroy
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
