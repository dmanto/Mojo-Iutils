use strict;
use Test::More 0.98;
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::Util 'monkey_patch';
use Mojo::Iutils::Server;
use Mojo::Iutils::Client;

has 'broker_id';
my @events;
my $disconnected;
my $connection_timeouts;
my $rename_timeouts;

sub ievents {
  my $self = shift;
  push @events, $self->broker_id;
}

# subclass overriding
monkey_patch 'Mojo::Iutils::Client', read_ievents => \&ievents;
monkey_patch 'Mojo::Iutils::Server', read_ievents => \&ievents;

my $s1 = Mojo::Iutils::Server->new(broker_id => 1);
$s1->start;
ok defined $s1->port, "server port defined";
$s1->on(disconnected => sub { $disconnected = 1 });
my $c2 = Mojo::Iutils::Client->new(broker_id => 2, port => $s1->port);
my $c3 = Mojo::Iutils::Client->new(broker_id => 3, port => $s1->port);
my $c4 = Mojo::Iutils::Client->new(broker_id => 4, port => $s1->port);
$_->on(disconnected => sub { $disconnected++ }) for ($c2, $c3, $c4);
$_->on(connection_timeout => sub { $connection_timeouts++ })
  for ($c2, $c3, $c4);
$_->on(rename_timeout => sub { $rename_timeouts++ }) for ($c2, $c3, $c4);


$c2->connect;
$c3->connect;
$c4->connect;

my $end = 0;
my $tid = Mojo::IOLoop->timer(0.1 => sub { $end = 1; shift->stop });
Mojo::IOLoop->one_tick while !($c4->connected || $end);
Mojo::IOLoop->remove($tid);

ok $c2->connected, "Client 2 connected";
ok $c3->connected, "Client 3 connected";
ok $c4->connected, "Client 4 connected";

is keys %{$s1->{_conns}}, 3, "3 clients connected";
undef $c4;    # or go out of context, should close the connection immediatelly
is $disconnected, undef, 'no disconnect events on own destroy';

$end = 0;
$tid = Mojo::IOLoop->timer(0.1 => sub { $end = 1; shift->stop });
Mojo::IOLoop->one_tick while !(keys %{$s1->{_conns}} == 2 || $end);
Mojo::IOLoop->remove($tid);

is keys %{$s1->{_conns}}, 2, "client 4 immediatelly disconnected";

$c2->sync_remotes(undef, 0);

$end = 0;
$tid = Mojo::IOLoop->timer(0.1 => sub { $end = 1; shift->stop });
Mojo::IOLoop->one_tick while !(@events >= 2 || $end);
Mojo::IOLoop->remove($tid);
ok @events == 2, "s1 & c3 ievents received";
is_deeply [sort @events], [1, 3], "right ievents received for c2 emits";

@events = ();
$c3->sync_remotes(undef, 0);
$end = 0;
$tid = Mojo::IOLoop->timer(0.1 => sub { $end = 1; shift->stop });
Mojo::IOLoop->one_tick while !(@events >= 2 || $end);
Mojo::IOLoop->remove($tid);
ok @events == 2, "s1 & c2 ievents received";
is_deeply [sort @events], [1, 2], "right ievents received for c3 emits";

@events = ();
$s1->sync_remotes(1, 0);
$end = 0;
$tid = Mojo::IOLoop->timer(0.1 => sub { $end = 1; shift->stop });
Mojo::IOLoop->one_tick while !(@events >= 2 || $end);
Mojo::IOLoop->remove($tid);
ok @events == 2, "c2 & c3 ievents received";
is_deeply [sort @events], [2, 3], "right ievents received for s1 emits";

# server $s1 undef so client connections should be immediatelly closed
is $disconnected, undef, 'server not disconnected yet';
my $port = $s1->port;    # remember port number
undef $s1;
$end = 0;
$tid = Mojo::IOLoop->timer(.1 => sub { $end = 1; shift->stop });

Mojo::IOLoop->one_tick while (($c2->connected || $c3->connected) && !$end);
Mojo::IOLoop->remove($tid);

ok !$c2->connected, 'c2 disconnected';
ok !$c3->connected, 'c3 disconnected';
is $disconnected, 2, 'client disconnected events received';

is $connection_timeouts, undef, 'no connection timeouts yet';
$c2 = Mojo::Iutils::Client->new(
  broker_id          => 2,
  port               => $port,
  connection_timeout => .1,
  rename_timeout     => .2
);    # fast timeout
$c2->on(connection_timeout => sub { $connection_timeouts++ });
$c2->on(rename_timeout     => sub { $rename_timeouts++ });
$c2->connect;    # tryies to reconnect to some (unexisting now) port

$end = 0;
$tid = Mojo::IOLoop->timer(1 => sub { $end = 1; shift->stop });

Mojo::IOLoop->one_tick while (!$connection_timeouts && !$end);
Mojo::IOLoop->remove($tid);
is $connection_timeouts, 1, '1 client connection timeout event received';

# now starts a faulty server that allow connections but doesnt answer renames

Mojo::IOLoop->server({address => '127.0.0.1', port => $port} => sub { });

is $rename_timeouts, undef, 'no rename timeouts yet';
$c2->connect;    # tryies to reconnect to same port, (faulty server)

$end = 0;
$tid = Mojo::IOLoop->timer(1 => sub { $end = 1; shift->stop });

Mojo::IOLoop->one_tick while (!$rename_timeouts && !$end);
Mojo::IOLoop->remove($tid);
is $rename_timeouts, 1, '1 client rename timeout event received';

done_testing;
