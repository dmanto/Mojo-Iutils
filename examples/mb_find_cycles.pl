use Devel::Cycle;
use Mojo::Minibroker;

my $m = Mojo::Minibroker->new(mode => 'test', app_name => 'mojotest');

my $cl1 = $m->client;
my $cl2 = $m->client;
my $srv = $m->server;

# $m->sqlite->db->update(int_globals => {value => 0}, {key => 'port'});
$m->sqlite->db->delete(ievents => undef);    # clean all events

$srv->start;

# $cl1->connect;
# $cl2->connect;

# my @evs;
# $cl2->on(
#   tests => sub {
#     my ($self, $arg) = @_;
#     push @evs, $arg;
#   }
# );

# my $nevents = 3;

# # emit $nevents events
# $cl1->iemit(tests => $_) for 1 .. $nevents;
# Mojo::IOLoop->one_tick while @evs < $nevents;

# say STDERR "Eventos: ", @evs;

find_cycle($srv);
exit(0);