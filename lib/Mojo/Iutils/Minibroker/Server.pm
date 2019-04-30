package Mojo::Iutils::Minibroker::Server;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Scalar::Util 'weaken';
use Mojo::Util qw/steady_time/;
use Mojo::File;
use Mojo::IOLoop;
use Mojo::SQLite;
use Time::HiRes qw/sleep time/;

has 'sqlite';
has 'server_port';

# minimallist broker server
# Protocol definition:
#
# client --> server
#
# <destination1>[:<destination2...:destinationN]<space char><command char>[<content>]<EOR char>
#
# server --> client
#
# <origin><space char><command char>[<content>]<EOR char>
#
# where:
#   destination:  is the id number of the targetted remote client connection, as known by the server.
#                 : char separates id numbers when more than one targeted client is needed
#                 0 means all connected clients
#
#   origin:       is the id number of the originating client, as known by the server
#
#   space char:   space (0x20) char
#
#   command char: '?' asks for last activity of targeted clients. Server will return a string
#                 in the format ?<client id number 1>:<last activity 1>: ... <EOR char>.
#                 <last activity N> here is the epoch time in miliseconds from the last message
#                 received by the server from that client.
#                 <origin> will be '0' in this particular answer.
#                 on any other command char, server will just resend command and content to
#                 all indicated targets
#                 '!' is an order to close <destination> connection
#                 'S' (0x53 char) means Interprocess sincronization order. Client corresponding
#                 to destination will need to syncronize against local events table

has purge_threshold => sub { 600 };    # will purge
has purge_interval =>
  sub { 10 };    # amount of seconds between purges on table iemits

sub purge_events {
    my $self = shift;
    $self->sqlite->db->query(
        "delete from __mb_ievents where created <= datetime('now', ?)",
        -$self->purge_threshold . " seconds" );
    return $self;
}

# atomically looks for key 'port' on table __mb_global_ints whith values 0 or -1,
# changing to -2 and returning true (1)
# otherwise nothing happens and returns false (0)
# the -2 value should prevent other clients or servers from taken the lock
sub _check_and_lock {
    my $self = shift;
    my $db   = $self->sqlite->db;
    my $r    = $db->update(
        __mb_global_ints => { value => -2, tstamp => \"current_timestamp" },
        { key => 'port', value => { -in => [ 0, -1 ] } }
    );
    return $r->sth->rows;    # amount of updated rows (0 or 1)
}

# atomically looks for key 'port' on table __mb_global_ints whith value -2,
# changing to <$self->server_port> and returning true (1)
# otherwise nothing happens and returns false (0)
# the <$self->server_port> value should prevent other servers from trying to start running
sub _store_and_unlock {
    my $self = shift;
    my $db   = $self->sqlite->db;
    my $r    = $db->update(
        __mb_global_ints =>
          { value => $self->server_port, tstamp => \"current_timestamp" },
        { key => 'port', value => -2 }
    );
    return $r->sth->rows;    # amount of updated rows (0 or 1)
}

# atomically looks for key 'port' on table __mb_global_ints whith value equals to $self->server_port,
# changing it to <0>
# otherwise nothing happens
# allways return $self
# the <0> value should allow other servers lock it and to start running
sub _cleanup {
    my $self = shift;
    return $self unless $self->server_port;
    my $db = $self->sqlite->db;
    my $r  = $db->update(
        __mb_global_ints => { value => 0 },
        { key => 'port', value => $self->server_port }
    );
    return $self unless $r->sth->rows;    # amount of updated rows (0 or 1)
    $self->server_port(undef);
    Mojo::IOLoop->remove( $self->{_server_id} );
    Mojo::IOLoop->remove( $self->{_purger_id} );
    return $self;
}

sub start {
    my $self = shift;
    return undef unless $self->_check_and_lock;
    $self->{_conns}     = {};
    $self->{_server_id} = Mojo::IOLoop->server(
        { address => '127.0.0.1' } => sub {
            my ( $loop, $stream, $id ) = @_;
            $stream->timeout(0);
            my $origin = 'P_'
              . $stream->handle
              ->peerport;    # remote port as unique reference until rename
            my $stime = int( 1000 * steady_time );    # truncate should be ok
            $self->{_conns}{$origin} =
              { stream => $stream, init => $stime, last => $stime };
            weaken $self->{_conns}{$origin}{stream};

            # say STDERR "Server en $$, conexion desde $origin";
            my $pndg = '';
            $stream->on(
                read => sub {
                    my ( $stream, $bytes ) = @_;
                    return unless defined $bytes;

                    # say STDERR "<---server recibio $bytes";
                    my @msgs = split /\n/, $pndg . $bytes,
                      -1;    # keep last separator
                    $pndg = pop @msgs // '';
                    $self->{_conns}{$origin}{last} = int( 1000 * steady_time )
                      if @msgs;
                    for my $msg (@msgs) {
                        next unless $msg && $msg =~ /(\S+)\s(\S)(.*)/;
                        my ( $d, $cmd, $content ) = ( $1, $2, $3 );
                        if ( $cmd eq '@' ) {    # rename cmd
                             # my $odd = 'Lista actual: ' . join(', ', keys %{$self->{_conns}});
                             # say STDERR $odd;
                            $self->{_conns}{$content} =
                              $self->{_conns}{$origin};
                            delete $self->{_conns}{$origin};
                            $origin = $content;
                            $stream->write("0 A\n");    # acknowledges rename
                             # my $ndd = 'Nueva lista: ' . join(', ', keys %{$self->{_conns}});
                             # say STDERR $ndd;
                            next;
                        }
                        my @dests =
                          $d
                          ? split /:/, $d
                          : keys %{ $self->{_conns} };
                        my $status = '';
                        my $ddd    = "=== Desde $$ lista a enviar: "
                          . join( ', ', @dests );

                        # say STDERR $ddd;
                        for my $dp (@dests) {
                            next unless $self->{_conns}{$dp};
                            if ( $cmd eq '?' ) {
                                my $aux = $self->{_conns}{$dp};
                                $status .= ":$dp:" . join ';',
                                  map { $_, $aux->{$_} } grep !/stream/,
                                  keys %$aux;
                                next;
                            }
                            next if $dp eq $origin;
                            if ( $cmd =~ /\w/ ) {

                             # say STDERR "server enviara $origin $cmd$content";
                                $self->{_conns}{$dp}{stream}
                                  ->write("$origin $cmd$content\n");
                            }
                            elsif ( $cmd eq '!' ) {    # close $dp connection
                                delete $self->{_conns}{$dp};
                            }
                        }
                        if ($status) {    # note first ':' works as cmd
                            $self->{_conns}{$origin}{stream}
                              ->write("0 $status\n");
                        }
                    }
                }
            );
            $stream->on(
                close => sub {
                    delete $self->{_conns}{$origin};
                    my $left = join ':', keys %{ $self->{_conns} };

             # say STDERR "$$: recibio close para puerto $origin, quedan $left";
                    $loop->stop
                      unless keys %{ $self->{_conns} }
                      ;    # keep running if has connectons
                }
            );
            $stream->on(
                error => sub {
                    delete $self->{_conns}{$origin};
                    $loop->stop
                      unless keys %{ $self->{_conns} }
                      ;    # keep running if has connectons
                }
            );
        }
    );

    $self->server_port( Mojo::IOLoop->acceptor( $self->{_server_id} )->port );
    $self->{_purger_id} = Mojo::IOLoop->recurring(
        $self->purge_interval => sub { $self->purge_events; } );
    $self->_store_and_unlock or die "Couldn't store new server port in db";
    return $self;
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

=head2 sqlite

    my $sqlite = $server->sqlite;
    $server    = $server->sqlite(Mojo::SQLite->new);

L<Mojo::SQLite> object used to sync processes, avoid any other server process to start and
hold port information so clients can connect to it

=head1 METHODS

L<Mojo::Iutils::Minibroker::Server> inherits all methods from L<Mojo::EventEmitter> and implements
the following ones:

=head2 purge_events

  $srv->purge_events;

Used to purge Minibroker server old events

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

L<Mojolicious>, L<Mojo::Iutils::Minibroker>, L<Mojo::Iutils::Minibroker::Server>, L<Mojo::SQLite>

=cut

