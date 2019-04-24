use strict;
use warnings;


BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;

use Test2::IPC;
use Test2::V0;
use Mojo::Iutils::Minibroker;
use Mojo::File 'path';
use Time::HiRes qw /sleep time/;

$ENV{MOJO_MODE} = 'test';
my $m = Mojo::Iutils::Minibroker->new(mode => 'test', app_name => 'mojotest');
my $db = $m->sqlite->db;
$db->query('drop table if exists auxtable');
$db->query('
create table auxtable (
    key text not null primary key,
    ivalue integer,
    tvalue text
)');
$db->insert(auxtable => {key => 'sync',           ivalue => 0});
$db->insert(auxtable => {key => 'server_started', ivalue => 0});

my $cforks = 3;

for my $nfork (1 .. $cforks) {
  die "fork: $!" unless defined(my $pid = fork);
  next if $pid;

  # childs
  # NO tests inside child code pls

  my @evs;
  my $m = Mojo::Iutils::Minibroker->new(mode => 'test', app_name => 'mojotest');
  my $db = $m->sqlite->db;
  my $server_started;

  while (!$server_started) {
    $server_started
      = $db->select(auxtable => ['ivalue'], {key => 'server_started'})
      ->hash->{ivalue};

    sleep .05;    # be nice with other kids
  }

  say STDERR "child $nfork encontro server";

  my $cl = $m->client;
  $cl->connect;

  say STDERR "child $nfork conectara a puerto: " . $cl->{broker_port};

  # wait for server acknowledge of names (_uids);
  # say STDERR "child $nfork antes de connection ready";

  while (!$cl->{connection_ready}) {
    Mojo::IOLoop->one_tick;
    sleep .1;
  }

  say STDERR "child $nfork despues de connection ready";
  $cl->sender_counter(0)->receiver_counter(0);
  $cl->on(
    test1 => sub {
      shift;
      push @evs, @_;
    }
  );

  $db->update(auxtable => {ivalue => \"ivalue+1"}, {key => 'sync'});
  my $sync = 0;

  while ($sync < $cforks) {
    $sync
      = $db->select(auxtable => ['ivalue'], {key => 'sync'})->hash->{ivalue};

    say STDERR "child $nfork lee sync $sync";
    sleep .25;    # be nice with other kids
  }
  $cl->iemit(test1 => "from child # $nfork");

  Mojo::IOLoop->recurring(
    .15 => sub {
      my $loop = shift;
      Mojo::IOLoop->stop
        if $cl->sender_counter == 1 && $cl->receiver_counter == ($cforks - 1);
    }
  );
  Mojo::IOLoop->start;
  $db->update(auxtable => {ivalue => \"ivalue+1"}, {key => 'sync'});

  say STDERR "$$: incremento sync a $sync";
  while ($sync < 2 * $cforks) {
    $sync
      = $db->select(auxtable => ['ivalue'], {key => 'sync'})->hash->{ivalue};

    say STDERR "child $nfork lee sync $sync";
    # $cl->_read_ievent;
    sleep .15;    # same as before
  }

  $db->insert(auxtable => {key => "sal$nfork", tvalue => join(':', @evs)});
  sleep .05;
  exit(0);
}
my $srv = $m->server;
$srv->start;

say STDERR "Server inicia en $$";
$db->update(auxtable => {ivalue => 1}, {key => 'server_started'});
Mojo::IOLoop->start;
wait();
my $sync = 0;

while ($sync < 2 * $cforks) {
  $sync = $db->select(auxtable => ['ivalue'], {key => 'sync'})->hash->{ivalue};
  sleep .05;    # be nice with other kids
}
sleep .5;
is $sync, 2 * $cforks, 'sync';
my @end_result;
push @end_result, sprintf "from child # $_"
  for sort 1 .. $cforks;    # alfanumeric sort (i.e. 10 < 2)
is [
  sort split(
    ':', $db->select(auxtable => ['tvalue'], {key => 'sal1'})->hash->{tvalue}
  )
  ],
  \@end_result, 'child #1 events';

# $c->DESTROY;
done_testing;
