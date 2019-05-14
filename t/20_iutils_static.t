# this tests are for static unit tests on Iutils module (no ioloop steps)
BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;
use strict;
use Test::More 0.98;
use Mojo::Iutils;
use Mojo::File 'path';
use File::HomeDir;
use File::Spec::Functions 'tmpdir';

delete $ENV{MOJO_MODE};
delete $ENV{MOJO_IUTILS_NAME};
my $m = Mojo::Iutils->new;
is $m->db_file,
  path(File::HomeDir->my_home, '.iutils', 'noname', 'development.db')
  ->to_string, 'correct home db_file, no mode';

$m = Mojo::Iutils->new(mode => 'test', name => 'mojotest');
is $m->db_file,
  path(File::HomeDir->my_home, '.iutils', 'mojotest', 'test.db')->to_string,
  'correct home db_file, no MOJO_MODE';
$ENV{MOJO_MODE} = 'test';
$m = Mojo::Iutils->new;
is $m->db_file,
  path(File::HomeDir->my_home, '.iutils', 'noname', 'test.db')->to_string,
  'correct home db_file, with MOJO_MODE set';

$ENV{MOJO_IUTILS_NAME}
  = 'iu-tst-nme';    # a fancy name, as will do some destructive stuff in the db
$m = Mojo::Iutils->new;
is $m->db_file,
  path(File::HomeDir->my_home, '.iutils', 'iu-tst-nme', 'test.db')->to_string,
  'correct home db_file, with MOJO_MODE and MOJO_IUTILS_NAME set';

# lock scheme for server after other sever set port value

$m->sqlite->db->update(
  __mb_global_ints => {value => 10000, tstamp => \"current_timestamp"},
  {key => 'port'}
);
is $m->_check_n_get_server_lock, 0, "other server already locked";

# lock scheme for no server active

$m->sqlite->db->update(
  __mb_global_ints => {value => 0, tstamp => \"current_timestamp"},
  {key => 'port'}
);
is $m->_check_n_get_server_lock,    1, "gets server lock";
is $m->_check_n_get_server_lock,    0, "only one server lock";
is $m->_check_n_get_server_TO_lock, 0, "recent lock";


# now we record timestamp with a time 3 seconds in the past
$m->sqlite->db->update(
  __mb_global_ints => {value => -1, tstamp => \"datetime('now', '-3 seconds')"},
  {key => 'port'}
);

# that will trigger the 2 seconds timeout
is $m->_check_n_get_server_TO_lock, 1, "gets timeout lock";

# now we record timestamp with a time in the future
$m->sqlite->db->update(
  __mb_global_ints => {value => -1, tstamp => \"datetime('now', '1 second')"},
  {key => 'port'}
);

# that will trigger the invalid (future) timeout
is $m->_check_n_get_server_TO_lock, 1,
  "gets timeout lock because of invalid tstamp (future)";

ok $m->{_broker_id} =~ /^\d+$/, "got broker id";
my $m2 = Mojo::Iutils->new;    # 2nd object in same test db
ok $m->{_broker_id} != $m2->{_broker_id}, "broker ids are different";

# events. First we wipe off __mb_ievents table

$m->sqlite->db->delete('__mb_ievents');

my (@e1, @e2, @e3);
$m->on(event1 => sub { shift; push @e1, [@_] });
$m->on(event2 => sub { shift; push @e2, [@_] });
$m->on(event3 => sub { shift; push @e3, [@_] });

# now we store some events on $m2, then they will be triggered on $m
$m2->_write_ievent(0 => event1 => (3, 2, 1));
$m2->_write_ievent(0 => event2 => {alpha => '⍺'});
$m2->_write_ievent(0 => event3 => [{}, {another => -1}]);
$m2->_write_ievent(0 => event4 => undef)
  ;    # note there is no subscriber for event 4

# now we read events
$m->read_ievents;
is_deeply [@e1], [[3, 2, 1]], "event1 ok";
is_deeply [@e2], [[{alpha => '⍺'}]], "event2 (utf8) ok";
is_deeply [@e3], [[[{}, {another => -1}]]], "event3 ok";

# $srv->start;
# $cl->connect;
# $cl2->connect;

# # check uniq _uid obtention
# like $cl->{_uid},  qr/\d+/, 'cl got valid _uid';
# like $cl2->{_uid}, qr/\d+/, 'cl2 got valid _uid';
# isnt $cl2->{_uid}, $cl->{_uid}, 'different _uids';

# # wait for server acknowledge of names (_uids);
# Mojo::IOLoop->one_tick
#   while !$cl->{connection_ready} || $cl2->{connection_ready};
# my @pings;
# $cl->on(
#   pong_received => sub {
#     my ($self, $o, $cnt) = @_;
#     push @pings, $o, $cnt;
#   }
# );
# my $dport = $cl2->{_uid};
# $cl->_ping($dport => 'test 001');
# Mojo::IOLoop->one_tick while !@pings;
# is [@pings], [$cl2->{_uid}, 'PONG: test 001'], 'pong received';
# my @server_status;
# $cl->on(
#   server_status => sub {
#     my ($self, $status) = @_;
#     push @server_status, $status;
#   }
# );
# $cl->_server_status;
# Mojo::IOLoop->one_tick while !@server_status;
# my ($cl_init,  $cl_last)  = @{$server_status[0]->{$cl->{_uid}}}{qw/init last/};
# my ($cl2_init, $cl2_last) = @{$server_status[0]->{$cl2->{_uid}}}{qw/init last/};
# like $cl_init, qr/\d+\.?\d*/,
#   'only valid float or integer numbers and in init time';
# ok $cl_init <= $cl_last,   'right secuence in cl';
# ok $cl2_init <= $cl2_last, 'right secuence in cl2';

# my @evs;
# $cl->sender_counter(0)->receiver_counter(0);
# $cl->on(
#   test1 => sub {
#     my $self = shift;
#     push @evs, [@_];
#   }
# );
# $cl->iemit(test1 => (alpha => '⍺'));
# $cl2->iemit(test1 => (beta => 'β'));
# Mojo::IOLoop->one_tick while @evs < 2;

# is \@evs, [[alpha => '⍺'], [beta => 'β']], 'got local and ipc event';

# # check unique event name
# my $uniquecl_1  = $cl->unique;
# my $uniquecl_2  = $cl->unique;
# my $uniquecl2_1 = $cl2->unique;

# like $uniquecl_1, qr/^__\d+_\d+$/, "right unique format";
# isnt $uniquecl_1, $uniquecl_2,  "uniqs are different";
# isnt $uniquecl_1, $uniquecl2_1, "unique differ on different objects";

# my @unique_evs;
# $cl->sender_counter(0)->receiver_counter(0);
# $cl->on(
#   $uniquecl_1 => sub {
#     my $self = shift;
#     push @unique_evs, [@_];
#   }
# );
# $cl2->iemit($uniquecl_1 => (gamma => 'γ'));
# Mojo::IOLoop->one_tick while @unique_evs < 1;
# is \@unique_evs, [[gamma => 'γ']], 'got unique event';

done_testing;
