package Mojo::Iutils::Minibroker;
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
use Mojo::Iutils::Minibroker::Client;
use Mojo::Iutils::Minibroker::Server;

use constant {MINIBROKER_DIR => '.minibroker',
  DEBUG => $ENV{MOJO_IUTILS_DEBUG} || 0,};
our $VERSION = '0.06';

has db_file => sub {
  my $self = shift;
  my $p;
  $p = $self->use_temp_dir
    ? path(tmpdir,
    MINIBROKER_DIR . '_'
      . (eval { scalar getpwuid($<) } || getlogin || 'nobody'))
    : path(File::HomeDir->my_home, MINIBROKER_DIR);
  $p = path($self->base_dir, MINIBROKER_DIR) if $self->base_dir;
  $p = $p->child($self->app_name // 'noname');
  $p->make_path;
  $p = $p->child($self->mode . '.db');
  return $p->to_string;
};

has client => sub {
  my $self = shift;
  $self->{_has_client} = 1;

  # state $client =
  Mojo::Iutils::Minibroker::Client->new(sqlite => $self->sqlite, @_);
};
has server => sub {
  my $self = shift;
  $self->{_has_server} = 1;

  # state $server =
  Mojo::Iutils::Minibroker::Server->new(sqlite => $self->sqlite, @_);
};
has sqlite => sub { Mojo::SQLite->new('sqlite:' . shift->db_file) };
has mode => sub { $ENV{MOJO_MODE} || $ENV{PLACK_ENV} || 'development' };
has [qw(app_name base_dir use_temp_dir sender_counter receiver_counter)];

sub new {
  my $self = shift->SUPER::new(@_);
  $self->sqlite->auto_migrate(1)->migrations->name('minibroker')->from_data;
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

__DATA__

@@ minibroker
-- 1 up
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
drop table if exists __mb_global_ints;

