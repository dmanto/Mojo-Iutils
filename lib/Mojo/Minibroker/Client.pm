package Mojo::Minibroker::Client;
use Mojo::Base 'Mojo::EventEmitter';

use Carp 'croak';
use Time::HiRes qw/time sleep/;
use Scalar::Util 'weaken';
use Mojo::File;
use Mojo::IOLoop;
use Mojo::SQLite;

has 'sqlite';
has get_broker_port_timeout   => sub {10};
has client_connection_timeout => sub {5};
has [qw/sender_counter receiver_counter/];

# atomycally looks for key 'port' on table __mb_global_ints whith a value of 0,
# changing to -1 and returning true (1)
# otherwise nothing happens and returns false (0)
# the -1 value should prevent other clients from taken the lock, but would
# not prevent servers from doing so
sub _check_and_lock {
  my $self = shift;
  my $db   = $self->sqlite->db;
  my $r    = $db->update(
    __mb_global_ints => {value => -1, tstamp => \"current_timestamp"},
    {key => 'port', value => 0}
  );
  return $r->sth->rows;    # amount of updated rows (0 or 1)
}

sub get_broker_port {
  my $self  = shift;
  my $db    = $self->sqlite->db;
  my $etime = time + $self->get_broker_port_timeout;
  my $broker_port;
  while (time < $etime) {
    $broker_port = $db->select(__mb_global_ints => ['value'], {key => 'port'})
      ->hashes->first->{value};
    last if $broker_port > 0;
    my $id = Mojo::IOLoop->timer(0.05 => sub { });
    Mojo::IOLoop->one_tick;    # be nice with this process ioloop
    Mojo::IOLoop->remove($id);
    sleep .05;                 # be nice with other processes
  }
  $self->{broker_port} = $broker_port > 0 ? $broker_port : undef;
  return $self;
}

sub get_last_ievents_id {
  my $self     = shift;
  my $last_row = $self->sqlite->db->select(
    sqlite_sequence => 'seq',
    {name => '__mb_ievents'}
  )->hashes->first // {seq => 0};
  $self->{_lieid} //= $last_row->{seq};
  say STDERR "Leyo last id en tabla: " . $last_row->{seq};
  return $self;
}

sub connect {
  my $self = shift;
  $self->get_broker_port;
  return $self unless $self->{broker_port};    # coudn't get broker port
  my $tid = Mojo::IOLoop->timer(
    10 => sub {
      my $loop = shift;

      # too bad, server not working
      die "Mojo::Minibroker::Client can't connect to broker";
    }
  );
  $self->get_last_ievents_id;          # no ievents before first connection
  delete $self->{_lport};              # no local port yet
  delete $self->{connection_ready};    # no valid connection yet
  $self->{id} = Mojo::IOLoop->client(
    {address => '127.0.0.1', port => $self->{broker_port}} => sub {
      my ($loop, $err, $stream) = @_;
      if ($stream) {
        my $pndg = '';                 # pending data
        $loop->remove($tid);           # no timeout
        $stream->timeout(0);           # permanent
        $stream->on(
          read => sub {
            my ($stream, $bytes) = @_;
            return unless defined $bytes;
            my @msgs = split /\n/, $pndg . $bytes, -1;    # keep last separator
            $pndg = pop @msgs // '';
            for my $msg (@msgs) {
              next unless $msg && $msg =~ /(\d+)\s(\S)(.*)/;
              my ($o, $cmd, $content) = ($1, $2, $3);
              if ($cmd eq 'S') {
                $self->_read_ievent;
                $loop->next_tick(sub { $self->{receiver_counter}++ });
              }
              elsif ($cmd eq 'A') {                       # name acknowledged
                $self->{connection_ready} = 1;
              }
              elsif ($cmd eq 'P' && $content =~ /^ING/) {
                $content =~ s/I/O/;                       # PONG
                $self->{_stream}->write("$o P$content\n");
              }
              elsif ($cmd eq 'P'
                && $content =~ /^ONG/
                && $self->{events}{pong_received})
              {
                $self->emit(pong_received => ($o, "$cmd$content"));
              }
              elsif ($cmd eq ':' && $content && $self->{events}{server_status})
              {
                my %status = split /:/, $content;
                for my $p (keys %status) {
                  $status{$p} = {split /;/, $status{$p}};
                }
                $self->emit(server_status => {%status});
              }
            }
          }
        );
        $stream->on(
          close => sub {
            delete $self->{_stream};
          }
        );
        my $aux_stream = $stream;
        $self->{_stream} = $aux_stream;                 # for interprocess emits
        $self->{_lport}  = $stream->handle->sockport;   # as a client id
        $self->_generate_base_uid;    # use 1st local port obtained
        $self->_rename;
        weaken($self->{_stream});
      }
    }
  );

  my $etime = time + $self->client_connection_timeout;
  while (time < $etime) {
    last if $self->{_lport};
    my $id = Mojo::IOLoop->timer(0.05 => sub { });
    Mojo::IOLoop->one_tick;           # be nice with this process ioloop
    Mojo::IOLoop->remove($id);
    sleep .05;                        # be nice with other processes
  }
  return $self;
}

sub _write_ievent {
  my $self = shift;
  return $self->sqlite->db->query(
    'insert into __mb_ievents (target, origin, event, args) values (?,?,?,?)',
    shift, $self->{_uid}, shift, {json => [@_]})->last_insert_id;
}

sub _generate_base_uid {
  my $self = shift;
  if (!$self->{_uid}) {
    my $db = $self->sqlite->db;
    my $tx = $db->begin('exclusive');
    $self->{_uid} = $db->select(__mb_global_ints => ['value'], {key => 'uniq'})
      ->hash->{value};
    $db->update(
      __mb_global_ints => {value => $self->{_uid} + 1},
      {key => 'uniq'}
    );
    $tx->commit;
  }
  return $self;
}

sub _read_ievent {
  my $self = shift;
  $self->sqlite->db->query(
    'select id, target, event, args from __mb_ievents where id > ? and target in (?,?) and origin <> ? order by id',
    $self->{_lieid},
    $self->{_uid},
    0,
    $self->{_uid}
  )->expand(json => 'args')->hashes->each(sub {
    my $e = shift;
    $self->emit($e->{event}, @{$e->{args}}) if $self->{events}{$e->{event}};
    $self->{_lieid} = $e->{id};
  });
}

sub _rename {
  my $self = shift;
  my $name = $self->{_uid};
  $self->{_stream}->write("0 \@$name\n");
  return $self;
}

sub iemit {
  my ($self, $event) = (shift, shift);
  my @args = @_;
  my $dest = 0;    # broadcast to all connections

  my ($local_emit, $remote_emit);
  if ($event =~ /^__(\d+)_\d+$/) {    # unique send
    $dest        = $1;
    $local_emit  = $self->{_uid} eq $dest;
    $remote_emit = !$local_emit;
  }
  else {
    $local_emit = $remote_emit = 1;
  }

  # CAVEAT $self->{events} hash is not docummented in Mojo::EE
  $self->emit($event, @args) if $local_emit && $self->{events}{$event};

  $self->_write_ievent($dest => $event => @args) and $self->{_stream}->write(
    "$dest S\n" => sub {
      $self->{sender_counter}++;
    }
  ) if $remote_emit;
  return $self;
}

sub ping {
  my ($self, $d, $cont) = @_;
  $cont = $cont ? ": $cont" : '';
  $self->{_stream}->write("$d PING$cont\n");
}

sub unique {
  my $self = shift;
  return '__' . $self->{_uid} . '_' . ++$self->{_unique_count};
}

sub server_status {
  shift->{_stream}->write("0 ?\n");
}

sub _cleanup {
  my $self = shift;
  $self->{_stream}->close if $self->{_stream};
}

sub DESTROY {
  Mojo::Util::_global_destruction()
    or shift->_cleanup and say STDERR "paso por client _cleanup";
}

1;

=encoding utf8

=head1 NAME

Mojo::Minibroker::Client - Minibroker front end

=head1 SYNOPSYS

    use Mojo::Minibroker::Client

=head1 DESCRIPTION

L<Mojo::Minibroker::Client> is the frontend to connect to the L<Mojo::Minibroker> ad-hoc
broker (almost serverless broker)

=head1 ATTRIBUTES

L<Mojo::Minibroker::Client> inherits all attributes from L<Mojo::EventEmitter> and implements
the following ones:

=head2 sqlite

    my $sqlite = $client->sqlite;
    $client    = $client->sqlite(Mojo::SQLite->new);

L<Mojo::SQLite> object used to sync processes, and to store all data.

=head1 METHODS

L<Mojo::Minibroker::Client> inherits all methods from L<Mojo::EventEmitter> and implements
the following ones:

=head2 new

Construct a new L<Mojo::Minibroker::Client> object.

=head1 AUTHOR

Daniel Mantovani <dmanto@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2019 by Daniel Mantovani.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 SEE ALSO

L<Mojolicious>, L<Mojo::SQLite>

=cut
