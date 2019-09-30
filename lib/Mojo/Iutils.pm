package Mojo::Iutils;
use Mojo::Base 'Mojo::EventEmitter';
use Carp 'croak';
use Scalar::Util 'weaken';
use Time::HiRes qw/sleep/;
use File::Spec::Functions 'tmpdir';
use File::HomeDir;
use Mojo::IOLoop;
use Mojo::File 'path';
use Mojo::Util qw/steady_time monkey_patch/;
use Mojo::SQLite;
use Mojo::Iutils::Client;
use Mojo::Iutils::Server;

# use Mojo::Loader qw/data_section/;
use Data::Dumper;
use constant {
    MOJO_IUTILS_DIR => '.iutils',
    DEBUG           => $ENV{MOJO_IUTILS_DEBUG} || 0,
};
our $VERSION = '0.09';

# subclass overriding
monkey_patch 'Mojo::Iutils::Client', read_ievents => \&read_ievents;
monkey_patch 'Mojo::Iutils::Server', read_ievents => \&read_ievents;

has db_file => sub {
    my $self = shift;
    my $p;
    $p =
      $self->use_temp_dir
      ? path( tmpdir,
        MOJO_IUTILS_DIR . '_'
          . ( eval { scalar getpwuid($<) } || getlogin || 'nobody' ) )
      : path( File::HomeDir->my_home, MOJO_IUTILS_DIR );
    $p = path( $self->base_dir, MOJO_IUTILS_DIR ) if $self->base_dir;
    $p = $p->child( $self->name );
    $p->make_path;
    $p = $p->child( $self->mode . '.db' );
    return $p->to_string;
};

has sqlite => sub { Mojo::SQLite->new( 'sqlite:' . shift->db_file ) };
has mode   => sub { $ENV{MOJO_MODE} || $ENV{PLACK_ENV} || 'development' };
has name   => sub { $ENV{MOJO_IUTILS_NAME} || 'noname' };
has pool_interval      => sub { 0.25 };
has pool_duration      => sub { 2 };
has purge_threshold    => sub { 600 };    # will purge older events
has purge_interval     => sub { 10 };     # check purges on table iemits
has connection_timeout => sub { 2 };      # refused connection
has rename_timeout =>
  sub { shift->connection_timeout + 2 };    # when server doesnt ack rename
has wait_running_timeout =>
  sub { shift->rename_timeout + 2 };        # will wait for a new object running
has integrity_interval => sub { 5 };        # server checks port ok
has [qw(base_dir use_temp_dir sender_counter receiver_counter)];

sub client {
    my $self = shift;
    $self->{client} //= Mojo::Iutils::Client->new(@_);
    return $self->{client};
}

sub server {
    my $self = shift;
    $self->{server} //= Mojo::Iutils::Server->new(@_);
    return $self->{server};
}

# atomically looks for key 'port' on table __mb_global_ints whith value equals to $self->{_server_port},
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

# atomically looks for key 'port' on table __mb_global_ints whith a value of 0,
# changing to -1 and returning true (1)
# otherwise nothing happens and returns false (0)
# the -1 value should prevent other clients or potencial servers from taken the lock.
#
sub _check_n_get_server_lock {
    my $self = shift;
    my $db   = $self->sqlite->db;
    my $r    = $db->update(
        __mb_global_ints => { value => -1, tstamp => \"current_timestamp" },
        { key => 'port', value => 0 }
    );
    return $r->sth->rows;    # amount of updated rows (0 or 1)
}

# atomically looks for key 'port' on table __mb_global_ints whith a value of -1 (or less, but shouldn't happen),
# but an old timestamp (older than 2 seconds)
# setting value to -1 , updating the timestamp and returning true (1)
# otherwise nothing happens and returns false (0)
# the -1 value should prevent other clients or potencial servers from taken the lock.
#
sub _check_n_get_server_TO_lock {
    my $self = shift;
    my $db   = $self->sqlite->db;
    my $r    = $db->update(
        __mb_global_ints => { value => -1, tstamp => \"current_timestamp" },
        {
            key    => 'port',
            value  => { '<', 0 },
            tstamp => {
                -not_between =>
                  [ \"datetime('now', '-2 seconds')", \"datetime('now')" ]
            }
        }
    );
    return $r->sth->rows;    # amount of updated rows (0 or 1)
}

sub _check_n_get_server_port {
    my $self = shift;
    my $db   = $self->sqlite->db;
    my $broker_port =
      $db->select( __mb_global_ints => ['value'], { key => 'port' } )
      ->hashes->first->{value} // 0;
    $self->{_server_port} = $broker_port > 0 ? $broker_port : undef;

    # say STDERR "Leyo tabla __mb_global_ints, broker_id: "
    #   . $self->{_broker_id}
    #   . ", puerto leido: "
    #   . $broker_port;

    return !!$self->{_server_port};
}

sub _get_last_ievents_id {
    my $self     = shift;
    my $last_row = $self->sqlite->db->select(
        sqlite_sequence => 'seq',
        { name => '__mb_ievents' }
    )->hashes->first // { seq => 0 };
    $self->{_last_ievents_id} = $last_row->{seq};

    # say STDERR "Leyo last id en tabla: " . $last_row->{seq};
    return $self;
}

sub _write_ievent {
    my $self = shift;
    return $self->sqlite->db->query(
'insert into __mb_ievents (target, origin, event, args) values (?,?,?,?)',
        shift, $self->{_broker_id}, shift, { json => [@_] }
    )->last_insert_id;
}

sub _generate_broker_id {
    my $self = shift;
    if ( !$self->{_broker_id} ) {
        my $db = $self->sqlite->db;
        my $tx = $db->begin('exclusive');
        $self->{_broker_id} =
          $db->select( __mb_global_ints => ['value'], { key => 'uniq' } )
          ->hash->{value};
        $db->update(
            __mb_global_ints => { value => $self->{_broker_id} + 1 },
            { key => 'uniq' }
        );
        $tx->commit;
    }
    return $self;
}

sub read_ievents {
    my $self = shift;
    weaken $self;
    say STDERR "run read_ievents";
    my $parent = $self->can('parent_instance') ? $self->parent_instance : $self;
    $parent->sqlite->db->query(
'select id, target, event, args from __mb_ievents where id > ? and target in (?,?) and origin <> ? order by id',
        $parent->{_last_ievents_id},
        $parent->{_broker_id},
        0,
        $parent->{_broker_id}
    )->expand( json => 'args' )->hashes->each(
        sub {
            my $e = shift;
            say STDERR "... y tiene para emitir un evento: " . $e->{event};
            $parent->emit( $e->{event}, @{ $e->{args} } )
              if $parent->{events}{ $e->{event} };
            $parent->{receiver_counter}++;
            $parent->{_last_ievents_id} = $e->{id};
        }
    );

    # note that $self->broker_id is client's or server's broker_id
}

sub running {
    my $self = shift;
    return 1 == !!$self->server->port + !!$self->client->connected;
}

sub _pool {
    my $self = shift;
    weaken $self;
    $self->{_end_pool} = steady_time + $self->pool_duration;
    my $read_small_loop;
    $read_small_loop = sub {
        $self->read_ievents;    # actualize events
        Mojo::IOLoop->remove( $self->{_pool_id} ) if $self->{_pool_id};
        $self->{_pool_id} =
          Mojo::IOLoop->timer( $self->pool_interval => $read_small_loop )
          if $self->{_end_pool} > steady_time;
    };
    $read_small_loop->();
    return $self;
}

sub purge_events {
    my $self = shift;
    $self->sqlite->db->query(
        "delete from __mb_ievents where created <= datetime('now', ?)",
        -$self->purge_threshold . " seconds" );
    say STDERR "Llamo a purge_events";
    return $self;
}

sub _purge_events_pool {
    my $self = shift;
    return $self if $self->{_purge_id};
    weaken $self;
    my $purge_small_loop;
    $purge_small_loop = sub {
        Mojo::IOLoop->remove( delete $self->{_purge_id} ) if $self->{_purge_id};
        return unless $self->{server};    # this will stop the periodic purge
        $self->purge_events;
        $self->{_purge_id} =
          Mojo::IOLoop->timer( $self->purge_interval => $purge_small_loop );
    };
    $purge_small_loop->();
    return $self;
}

sub _server_integrity_check {
    my $self = shift;
    weaken $self;
    my $port = $self->{_server_port};

    # first case is a problem, no server according the DB
    return 0 unless $port && $port > 0;

    # next is everything ok case
    return 1 if $self->_check_n_get_server_port && $self->server->port == $port;

    # here it is also a problem, there is another server running according to db
    return 0;
}

sub _integrity_pool {
    my $self = shift;
    return $self if $self->{_integrity_id};
    weaken $self;
    my $integrity_small_loop;
    $integrity_small_loop = sub {
        Mojo::IOLoop->remove( delete $self->{_integrity_id} )
          if $self->{_integrity_id};
        return unless $self->{server};    # this will stop the periodic check
        $self->_server_integrity_check || $self->_connect;
        $self->{_integrity_id} =
          Mojo::IOLoop->timer(
            $self->integrity_interval => $integrity_small_loop );
    };
    $integrity_small_loop->();
    return $self;
}

sub _connect {
    my ( $package, $filename, $line ) = caller;
    my $self = shift;
    weaken $self;

    # say STDERR "llamo a _connect desde $line, broker_id: "
    #   . $self->{_broker_id};
    my $db = $self->sqlite->db;
    if ( $self->_check_n_get_server_port ) {

        undef $self->{client};

        # say STDERR "Intenta conectar desde linea $line "
        #   . " (broker_id  "
        #   . $self->{_broker_id}
        #   . " ) a puerto "
        #   . $self->{_server_port};
        $self->client(
            broker_id       => $self->{_broker_id},
            port            => $self->{_server_port},
            parent_instance => $self
        )->connect->on( disconnected => sub { $self->_connect_pool } );
        $self->client->on(
            connection_timeout => sub {

                # this is a problem. As a client, we were not able to
                # connect to the specified port, so we assume that the server
                # is not running

                say STDERR "Hubo un connection timeout, broker_id: "
                  . $self->{_broker_id}
                  . ", que trato de conectarse al puerto: "
                  . $self->{_server_port};

                $db->update(
                    __mb_global_ints => { value => 0 },
                    { key => 'port', value => $self->{_server_port} }
                );

               # note that if port value changes, last sentence will not update!
               # and retry connection now (probably as a server)
                $self->_connect_pool;
            }
        );
        $self->client->on(
            rename_timeout => sub {

                # Similar to last case, but we don't get the acknowledge to
                # the initial rename request.
                $db->update(
                    __mb_global_ints => { value => 0 },
                    { key => 'port' }
                );

                # and retry connection now (probably as a server)
                $self->_connect_pool;
            }
        );
    }
    elsif ($self->_check_n_get_server_lock
        || $self->_check_n_get_server_TO_lock )
    {
        undef $self->{server};
        if (
            my $port = $self->server(
                broker_id       => $self->{_broker_id},
                parent_instance => $self
            )->start->port
          )
        {
            # we are the server
            say STDERR "We are the server, broker_id: "
              . $self->{_broker_id}
              . ", nuevo puerto servidor: "
              . $port;
            $db->update(
                __mb_global_ints => { value => $port },
                { key => 'port' }
            );
            $self->{_server_port} = $port;
            $self->_purge_events_pool;

            # my $integrity_result = $self->_server_integrity_check;
            # say STDERR "Resultado del Integrity test: "
            #   . $integrity_result
            #   . ", broker_id: "
            #   . $self->{_broker_id};
        }
        else {
            # this is a problem. As a server, we were not able to
            # start listening on a valid port, so we assume that we should retry
            $db->update(
                __mb_global_ints => { value => 0 },
                { key => 'port' }
            );

            # and retry connection now (probably again as a server)
            $self->_connect_pool;
        }
    }
    $self->{_connection_wait} = .1;
}

sub _connect_pool {
    my $self = shift;
    weaken $self;
    undef $self->{client};    # will DESTROY client if exists
    undef $self->{server};    # will DESTROY server if exists
    my $connect_small_loop;
    $connect_small_loop = sub {
        $self->_connect
          unless $self->running;
        Mojo::IOLoop->remove( $self->{_connect_id} )
          if $self->{_connect_id};
        $self->{_connect_id} =
          Mojo::IOLoop->timer(
            $self->{_connection_wait} => $connect_small_loop );
    };
    $connect_small_loop->();
    return $self;
}

sub iemit {
    my ( $self, $event ) = ( shift, shift );
    my @args = @_;
    my $dest = 0;    # broadcast to all connections

    my ( $local_emit, $remote_emit );
    if ( $event =~ /^__(\d+)_\d+$/ ) {    # unique send
        $dest        = $1;
        $local_emit  = $self->{_broker_id} eq $dest;
        $remote_emit = !$local_emit;
    }
    else {
        $local_emit = $remote_emit = 1;
    }

    # CAVEAT $self->{events} hash is not docummented in Mojo::EE
    $self->emit( $event, @args ) if $local_emit && $self->{events}{$event};
    if ($remote_emit) {
        $self->_write_ievent( $dest => $event => @args );
        my $nc = $self->{_broker_id};

        # say STDERR "client $nc enviara $dest S";
        if ( $self->client->connected ) {
            $self->client->sync_remotes( $self->{_broker_id}, 0 );
            $self->{sender_counter}++;
        }
        elsif ( $self->server->port ) {
            $self->server->sync_remotes( $self->{_broker_id}, 0 );
            $self->{sender_counter}++;
        }
    }
    return $self;
}

sub unique {
    my $self = shift;
    return '__' . $self->{_broker_id} . '_' . ++$self->{_unique_count};
}

sub new {
    my $self = shift->SUPER::new(@_);
    $self->sqlite->auto_migrate(1)->migrations->name('minibroker')
      ->from_string(
        qq{-- 1 up
create table if not exists __mb_global_ints (
    key text not null primary key,
    value integer,
    tstamp text not null default current_timestamp
);
insert into __mb_global_ints (key, value) VALUES ('port', 0), ('uniq', 1);
create table if not exists __mb_ievents (
  id integer primary key autoincrement,
  target integer not null,
  origin integer not null,
  event text not null,
  args text not null,
  created text not null default current_timestamp
)

-- 1 down
drop table if exists __mb_ievents;
drop table if exists __mb_global_ints;}
      );

    # generate broker id
    $self->_generate_broker_id;
    $self->_get_last_ievents_id;

    # check for client or server mode
    # set purge interval
    $self->{_connection_wait} = 0;
    $self->_connect_pool;

    my $end = 0;
    my $tid = Mojo::IOLoop->timer(
        $self->wait_running_timeout => sub { $end = 1; shift->stop } );
    Mojo::IOLoop->one_tick while !( $self->running || $end );
    Mojo::IOLoop->remove($tid);

    return $self;
}

sub DESTROY {
    my $self = shift;
    return () if Mojo::Util::_global_destruction();
    if ( $self->{_purge_id} ) {
        say( "removera purge_id: ", $self->{_purge_id} );
        Mojo::IOLoop->remove( $self->{_purge_id} );
    }
    if ( $self->{_pool_id} ) {
        say( "removera pool_id: ", $self->{_pool_id} );
        Mojo::IOLoop->remove( $self->{_pool_id} );
    }
    say "Llamo al DESTROY de Mojo::Iutils";
}
1;

=encoding utf-8

=head1 NAME

Mojo::Iutils - Inter Process Communications Utilities without dependences

=head1 SYNOPSIS

	# hit counter, works with daemon, prefork & hypnotoad servers

	use Mojolicious::Lite;
	use Mojo::Iutils;

	helper iutils => sub {state $iutils = Mojo::Iutils->new};

	get '/' => sub {
		my $c = shift;

		# Increment persistent counter "mycounter" with a simple callback.
		# Locking / Unlocking is handled under the hood
		my $cnt = $c->iutils->istash(mycounter => sub {++$_[0]});
		$c->render(text => "Hello, this page was hit $cnt times (and I'm process $$ talking)");
	};

	app->start

	# emit interprocess events (ievent method), works with daemon, prefork & hypnotoad
	# (modified from chat.pl Mojolicious example)

	use Mojolicious::Lite;
	use Mojo::Iutils;
	
	helper events => sub { state $events = Mojo::Iutils->new };
	
	get '/' => 'chat';
	
	websocket '/channel' => sub {
	my $c = shift;

	$c->inactivity_timeout(3600);
	
	# Forward messages from the browser
	$c->on(message => sub { shift->events->iemit(mojochat => shift) });
	
	# Forward messages to the browser
	my $cb = $c->events->on(mojochat => sub { $c->send(pop) });
	$c->on(finish => sub { shift->events->unsubscribe(mojochat => $cb) });
	};
	
	# Minimal multiple-process WebSocket chat application for browser testing

	app->start;
	__DATA__
	
	@@ chat.html.ep
	<form onsubmit="sendChat(this.children[0]); return false"><input></form>
	<div id="log"></div>
	<script>
	var ws  = new WebSocket('<%= url_for('channel')->to_abs %>');
	ws.onmessage = function (e) {
		document.getElementById('log').innerHTML += '<p>' + e.data + '</p>';
	};
	function sendChat(input) { ws.send(input.value); input.value = '' }
	</script>

=head1 DESCRIPTION

Mojo::Iutils provides Persistence and Inter Process Events, without any external dependences beyond
L<Mojolicious> and L<Sereal> Perl Modules.

Its main intents are 1) to be used for microservices (because does not require external services, 
like a database or a pubsub external service, so lowers other dependences), and 2) being very portable, running at least in
main (*)nix distributions, OSX, and Windows (Strawberry perl for cmd users, default perl installation for Cygwin and WSL users)

=head1 EVENTS

L<Mojo::Iutils> inherits all events from L<Mojo::EventEmitter>.


=head1 ATTRIBUTES

L<Mojo::Iutils> implements the following attributes:

=head2 app_mode

  my $iutils = Mojo::Iutils->new(app_mode => 'test');

Used to force application mode. This value will be taken to generate the default base_dir attribute;

=head2 base_dir

  my $base_dir = $iutils->base_dir;
  $iutils = $iutils->base_dir($app->home('iutilsdir', $app->mode));

Base directory to be used by L<Mojo::Iutils>. Must be the same for different applications if they
need to communicate among them.

It should include the mode of the application, otherwise testing will probably interfere with production
files so you will not be able to test an application safelly on a production server.

Defaults for a temporary directory. It also includes the running user name, to avoid permission problems
on automatic (matrix) tester installations with different users (i.e. with and without sudo cpanm installs).

=head2 buffer_size

  my $buffer_size = $iutils->buffer_size;
  my $iutils = Mojo::Iutils->new(buffer_size => 512);
  $iutils = $iutils->buffer_size(1024);

The size of the circular buffer used to store events. Should be big enough to
handle slow attended events, or it will die with an overflow error.

=head1 METHODS

L<Mojo::Iutils> inherits all events from L<Mojo::EventEmitter>, and implements the following new ones:

=head2 iemit

  $iutils = $iutils->iemit('foo');
  $iutils = $iutils->iemit('foo', 123);

Emit event to all connected processes. Similar to calling L<Mojo::EventEmitter>'s emit method
in all processes, but doesn't emit an error event if event is not registered.

=head2 istash

  $iutils->istash(foo => 123);
  my $foo = $iutils->istash('foo'); # 123
  my %bar = $iutils->istash(bar => (baz => 23)); # %bar = (baz => 23)

It supports three modes of operation. Just get recorded data:

  my $scalar = $iutils->istash('foo');
  my @array = $iutils->istash('bar');
  my %hash = $iutils->istash('baz');

Set data (returning same data):

  my $scalar = $iutils->istash(foo => 'some scalar');
  my @array = $iutils->istash(bar => qw/some array/;
  my %hash = $iutils->istash(baz => (some => 'hash'));

Modify data with code

  $iutils->istash(foo => undef); # clears var foo
  $iutils->istash(foo => sub {my @z = @_; push @z, $x; @z}); # pushes $x to array in foo

The three operations are thread & fork safe. Get data gets a shared lock, while
set and modify get an exclusive lock.

=head2 new

  my $iutils = Mojo::Iutils->new;

Constructs a new L<Mojo::Iutils> object.

=head2 unique

  my $u = $iutils->unique;
  $iutils->on($u => sub {...}); # register event with unique name in same object

Then in other part of the code, in any process that knows $u value

  $other_iutils->emit($u => @args);

strings generated with this method are not broadcasted, but sent only to the target process

=head1 LICENSE

Copyright (C) Daniel Mantovani.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Daniel Mantovani E<lt>dmanto@cpan.orgE<gt>

=cut
