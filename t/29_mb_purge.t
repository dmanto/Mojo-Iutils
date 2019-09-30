BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;
use Test2::V0;
use Mojo::Iutils;

# this function will allow to fake time in CURRENT_TIMESTAMP's sqlite function

my $ftime = time;

sub faketime {
  my @ft = reverse((gmtime($ftime))[0 .. 5]);
  $ft[0] += 1900;
  $ft[1]++;

  # SQLite time format
  return sprintf '%04d-%02d-%02d %02d:%02d:%02d', @ft;
}


my $m1 = Mojo::Iutils->new(mode => 'test', app_name => 'mojotest');
$m1->sqlite->db->dbh->sqlite_create_function('current_timestamp', -1,
  \&faketime);

my $m2 = Mojo::Iutils->new(mode => 'test', app_name => 'mojotest');
$m2->sqlite->db->dbh->sqlite_create_function('current_timestamp', -1,
  \&faketime);

$m1->sqlite->db->update(__mb_global_ints => {value => 0}, {key => 'port'});
$m1->sqlite->db->delete(__mb_ievents => undef);    # clean all events

$ftime = time - 601;    # events that should be deleted

my @evs;
$m2->on(
  tests => sub {
    my ($self, $arg) = @_;
    push @evs, $arg;
  }
);

my $nevents = 3;

# emit $nevents events
$m1->iemit(tests => $_) for 1 .. $nevents;
Mojo::IOLoop->one_tick while @evs < $nevents;

$ftime = time - 590;    # events that should not be deleted

# emit $nevents more events
$m1->iemit(tests => $_) for $nevents + 1 .. 2 * $nevents;
Mojo::IOLoop->one_tick while @evs < 2 * $nevents;
is [@evs], [1 .. 2 * $nevents], 'rights events received';
is $m1->sqlite->db->select(__mb_ievents => [\'count(*)'])->array->[0],
  2 * $nevents, 'all __mb_ievents on db';
$m1->purge_events;
is $m1->sqlite->db->select(__mb_ievents => [\'count(*)'])->array->[0], $nevents,
  '__mb_ievents purged on db';
done_testing;
