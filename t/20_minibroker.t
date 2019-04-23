BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;
use Test2::IPC;
use Test2::V0;
use Mojo::Iutils::Minibroker;
use Mojo::File 'path';
use File::HomeDir;
use File::Spec::Functions 'tmpdir';

delete $ENV{MOJO_MODE};
my $m = Mojo::Iutils::Minibroker->new;
is $m->db_file,
  path(File::HomeDir->my_home, '.minibroker', 'noname', 'development.db')
  ->to_string, 'correct home db_file, no mode';

$m = Mojo::Iutils::Minibroker->new(mode => 'test', app_name => 'mojotest');
is $m->db_file,
  path(File::HomeDir->my_home, '.minibroker', 'mojotest', 'test.db')->to_string,
  'correct home db_file';
$ENV{MOJO_MODE} = 'test';
$m = Mojo::Iutils::Minibroker->new;
is $m->db_file,
  path(File::HomeDir->my_home, '.minibroker', 'noname', 'test.db')->to_string,
  'correct home db_file';

# lock scheme for server after client
my $cl  = $m->client;
my $srv = $m->server;

$m->sqlite->db->update(__mb_global_ints => {value => 0}, {key => 'port'});
is $cl->_check_and_lock,  1, "gets client lock";
is $cl->_check_and_lock,  0, "only one client lock";
is $srv->_check_and_lock, 1, "gets server lock";
is $srv->_check_and_lock, 0, "only one server lock";
is $cl->_check_and_lock,  0, "no client lock after server's";

# lock scheme for server after client

$m->sqlite->db->update(__mb_global_ints => {value => 0}, {key => 'port'});
is $srv->_check_and_lock, 1, "gets direct server lock";
is $srv->_check_and_lock, 0, "only one server lock (2nd)";
is $cl->_check_and_lock,  0, "no client lock after server's (2nd)";

# check timeout on get_port

is $cl->get_broker_port_timeout(.1)->get_broker_port->{broker_port}, undef,
  'timeout getting server port';
$m->sqlite->db->update(__mb_global_ints => {value => 1000}, {key => 'port'});
is $cl->get_broker_port->{broker_port}, 1000, 'gets server port';
$m->sqlite->db->update(__mb_global_ints => {value => 0}, {key => 'port'});

my $cl2 = Mojo::Iutils::Minibroker->new->client;    # 2nd client

$srv->start;
$cl->connect;
$cl2->connect;

# check uniq _uid obtention
like $cl->{_uid},  qr/\d+/, 'cl got valid _uid';
like $cl2->{_uid}, qr/\d+/, 'cl2 got valid _uid';
isnt $cl2->{_uid}, $cl->{_uid}, 'different _uids';

# wait for server acknowledge of names (_uids);
Mojo::IOLoop->one_tick
  while !$cl->{connection_ready} || $cl2->{connection_ready};
my @pings;
$cl->on(
  pong_received => sub {
    my ($self, $o, $cnt) = @_;
    push @pings, $o, $cnt;
  }
);
my $dport = $cl2->{_uid};
$cl->_ping($dport => 'test 001');
Mojo::IOLoop->one_tick while !@pings;
is [@pings], [$cl2->{_uid}, 'PONG: test 001'], 'pong received';
my @server_status;
$cl->on(
  server_status => sub {
    my ($self, $status) = @_;
    push @server_status, $status;
  }
);
$cl->_server_status;
Mojo::IOLoop->one_tick while !@server_status;
my ($cl_init,  $cl_last)  = @{$server_status[0]->{$cl->{_uid}}}{qw/init last/};
my ($cl2_init, $cl2_last) = @{$server_status[0]->{$cl2->{_uid}}}{qw/init last/};
like $cl_init, qr/\d+\.?\d*/,
  'only valid float or integer numbers and in init time';
ok $cl_init <= $cl_last,   'right secuence in cl';
ok $cl2_init <= $cl2_last, 'right secuence in cl2';

my @evs;
$cl->sender_counter(0)->receiver_counter(0);
$cl->on(
  test1 => sub {
    my $self = shift;
    push @evs, [@_];
  }
);
$cl->iemit(test1 => (alpha => '⍺'));
$cl2->iemit(test1 => (beta => 'β'));
Mojo::IOLoop->one_tick while @evs < 2;

is \@evs, [[alpha => '⍺'], [beta => 'β']], 'got local and ipc event';

# check unique event name
my $uniquecl_1  = $cl->unique;
my $uniquecl_2  = $cl->unique;
my $uniquecl2_1 = $cl2->unique;

like $uniquecl_1, qr/^__\d+_\d+$/, "right unique format";
isnt $uniquecl_1, $uniquecl_2,  "uniqs are different";
isnt $uniquecl_1, $uniquecl2_1, "different objects unique differ";

my @unique_evs;
$cl->sender_counter(0)->receiver_counter(0);
$cl->on(
  $uniquecl_1 => sub {
    my $self = shift;
    push @unique_evs, [@_];
  }
);
$cl2->iemit($uniquecl_1 => (gamma => 'γ'));
Mojo::IOLoop->one_tick while @unique_evs < 1;
is \@unique_evs, [[gamma => 'γ']], 'got unique event';


done_testing;
