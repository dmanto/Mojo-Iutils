BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;
use Test2::V0;
use Mojo::Iutils::Minibroker;

# this function will allow to fake time in CURRENT_TIMESTAMP's sqlite function

my $ftime = time;

sub faketime {
  my @ft = reverse((gmtime($ftime))[0 .. 5]);
  $ft[0] += 1900;
  $ft[1]++;

  # SQLite time format
  return sprintf '%04d-%02d-%02d %02d:%02d:%02d', @ft;
}


my $m = Mojo::Iutils::Minibroker->new(mode => 'test', app_name => 'mojotest');
$m->sqlite->db->dbh->sqlite_create_function('current_timestamp', -1,
  \&faketime);

my $cl1 = $m->client;
my $cl2 = $m->client;
my $srv = $m->server;

$m->sqlite->db->update(__mb_global_ints => {value => 0}, {key => 'port'});
$m->sqlite->db->delete(__mb_ievents => undef);    # clean all events

$srv->start;
$cl1->connect;
$cl2->connect;

$ftime = time - 601;    # events that should be deleted

my @evs;
$cl2->on(
  tests => sub {
    my ($self, $arg) = @_;
    push @evs, $arg;
  }
);

my $nevents = 3;

# emit $nevents events
$cl1->iemit(tests => $_) for 1 .. $nevents;
Mojo::IOLoop->one_tick while @evs < $nevents;

$ftime = time - 590;    # events that should not be deleted

# emit $nevents more events
$cl1->iemit(tests => $_) for $nevents + 1 .. 2 * $nevents;
Mojo::IOLoop->one_tick while @evs < 2 * $nevents;
is [@evs], [1 .. 2 * $nevents], 'rights events received';
is $m->sqlite->db->select(__mb_ievents => [\'count(*)'])->array->[0],
  2 * $nevents, 'all __mb_ievents on db';
$srv->purge_events;
is $m->sqlite->db->select(__mb_ievents => [\'count(*)'])->array->[0], $nevents,
  '__mb_ievents purged on db';
done_testing;
