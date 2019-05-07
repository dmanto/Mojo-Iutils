package Mojo::Iutils;
use Mojo::Base 'Mojo::EventEmitter';
use Carp 'croak';
use Scalar::Util 'weaken';
use Time::HiRes qw/sleep/;
use File::Spec::Functions 'tmpdir';
use File::HomeDir;
use Mojo::IOLoop;
use Mojo::File 'path';
use Mojo::Util;
use Mojo::SQLite;
use Mojo::Iutils::Client;
use Mojo::Iutils::Server;

# use Mojo::Loader qw/data_section/;
use Data::Dumper;
use constant {
    MOJO_IUTILS_SLBROKER_DIR => '.slbroker',
    DEBUG          => $ENV{MOJO_IUTILS_DEBUG} || 0,
};
our $VERSION = '0.09';

has db_file => sub {
    my $self = shift;
    my $p;
    $p =
      $self->use_temp_dir
      ? path( tmpdir,
        MOJO_IUTILS_SLBROKER_DIR . '_'
          . ( eval { scalar getpwuid($<) } || getlogin || 'nobody' ) )
      : path( File::HomeDir->my_home, MOJO_IUTILS_SLBROKER_DIR );
    $p = path( $self->base_dir, MOJO_IUTILS_SLBROKER_DIR ) if $self->base_dir;
    $p = $p->child( $self->name );
    $p->make_path;
    $p = $p->child( $self->mode . '.db' );
    return $p->to_string;
};

has client => sub {
    my $self = shift;
    $self->{_has_client} = 1;

    # state $client =
    Mojo::Iutils::Minibroker::Client->new( sqlite => $self->sqlite, @_ );
};
has server => sub {
    my $self = shift;
    $self->{_has_server} = 1;

    # state $server =
    Mojo::Iutils::Minibroker::Server->new( sqlite => $self->sqlite, @_ );
};
has sqlite => sub { Mojo::SQLite->new( 'sqlite:' . shift->db_file ) };
has mode   => sub { $ENV{MOJO_MODE} || $ENV{PLACK_ENV} || 'development' };
has name   => sub { $ENV{MOJO_MINIBROKER_NAME} || 'noname' };
has [qw(base_dir use_temp_dir sender_counter receiver_counter)];

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
sub _server_check_and_lock {
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
sub _server_store_and_unlock {
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

has get_broker_port_timeout   => sub { 10 };
has client_connection_timeout => sub { 5 };

# time between last event checked and new pool on local events table
has pool_time => sub { .25 };
has [qw/sender_counter receiver_counter/];

# atomically looks for key 'port' on table __mb_global_ints whith a value of 0,
# changing to -1 and returning true (1)
# otherwise nothing happens and returns false (0)
# the -1 value should prevent other clients from taken the lock, but would
# not prevent servers from doing so
sub _check_and_lock {
    my $self = shift;
    my $db   = $self->sqlite->db;
    my $r    = $db->update(
        __mb_global_ints => { value => -1, tstamp => \"current_timestamp" },
        { key => 'port', value => 0 }
    );
    return $r->sth->rows;    # amount of updated rows (0 or 1)
}

sub get_broker_port {
    my $self  = shift;
    my $db    = $self->sqlite->db;
    my $etime = time + $self->get_broker_port_timeout;
    my $broker_port;
    while ( time < $etime ) {
        $broker_port =
          $db->select( __mb_global_ints => ['value'], { key => 'port' } )
          ->hashes->first->{value};
        last if $broker_port > 0;
        my $id = Mojo::IOLoop->timer( 0.05 => sub { } );
        Mojo::IOLoop->one_tick;    # be nice with this process ioloop
        Mojo::IOLoop->remove($id);
        sleep .05;                 # be nice with other processes
    }
    $self->{broker_port} = $broker_port > 0 ? $broker_port : undef;
    return $self;
}

sub _get_last_ievents_id {
    my $self     = shift;
    my $last_row = $self->sqlite->db->select(
        sqlite_sequence => 'seq',
        { name => '__mb_ievents' }
    )->hashes->first // { seq => 0 };
    $self->{_lieid} //= $last_row->{seq};

    # say STDERR "Leyo last id en tabla: " . $last_row->{seq};
    return $self;
}

sub _write_ievent {
    my $self = shift;
    return $self->sqlite->db->query(
'insert into __mb_ievents (target, origin, event, args) values (?,?,?,?)',
        shift, $self->{_uid}, shift, { json => [@_] }
    )->last_insert_id;
}

sub _generate_base_uid {
    my $self = shift;
    if ( !$self->{_uid} ) {
        my $db = $self->sqlite->db;
        my $tx = $db->begin('exclusive');
        $self->{_uid} =
          $db->select( __mb_global_ints => ['value'], { key => 'uniq' } )
          ->hash->{value};
        $db->update(
            __mb_global_ints => { value => $self->{_uid} + 1 },
            { key => 'uniq' }
        );
        $tx->commit;
    }
    return $self;
}

sub read_ievents {
    my $self = shift;
    $self->sqlite->db->query(
'select id, target, event, args from __mb_ievents where id > ? and target in (?,?) and origin <> ? order by id',
        $self->{_lieid},
        $self->{_uid},
        0,
        $self->{_uid}
    )->expand( json => 'args' )->hashes->each(
        sub {
            my $e = shift;
            $self->emit( $e->{event}, @{ $e->{args} } )
              if $self->{events}{ $e->{event} };
            $self->{receiver_counter}++;
            $self->{_lieid} = $e->{id};
        }
    );
    Mojo::IOLoop->timer( $self->pool_time => sub { $self->_read_ievent } );
}


sub iemit {
    my ( $self, $event ) = ( shift, shift );
    my @args = @_;
    my $dest = 0;    # broadcast to all connections

    my ( $local_emit, $remote_emit );
    if ( $event =~ /^__(\d+)_\d+$/ ) {    # unique send
        $dest        = $1;
        $local_emit  = $self->{_uid} eq $dest;
        $remote_emit = !$local_emit;
    }
    else {
        $local_emit = $remote_emit = 1;
    }

    # CAVEAT $self->{events} hash is not docummented in Mojo::EE
    $self->emit( $event, @args ) if $local_emit && $self->{events}{$event};
    if ($remote_emit) {
        $self->_write_ievent( $dest => $event => @args );
        my $nc = $self->{_uid};

        # say STDERR "client $nc enviara $dest S";
        $self->{_stream}->write("$dest S\n");
        $self->{sender_counter}++;
    }
    return $self;
}

sub unique {
    my $self = shift;
    return '__' . $self->{_uid} . '_' . ++$self->{_unique_count};
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

  # check for client or server mode
    $self->{_purger_id} = Mojo::IOLoop->recurring(
        $self->purge_interval => sub { $self->purge_events; } );
    $self->_store_and_unlock or die "Couldn't store new server port in db";


    return $self;
}




sub DESTROY {
    my $self = shift;
    return () if Mojo::Util::_global_destruction();

    # say STDERR "Al destroy de minibroker si lo llama";
    $self->client->DESTROY if delete $self->{_has_client};
    $self->server->DESTROY if delete $self->{_has_server};
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
