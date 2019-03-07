BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;
use Test2::IPC;
use Test2::V0;
use Mojo::Iutils;
use Mojo::File 'path';

$ENV{MOJO_MODE} = 'test';

my $c = Mojo::Iutils->new;
is eval { $c->_get_buffers_path("NaN") }, undef, "should be a number";
like $c->_get_buffers_path(1), qr/E0000001$/, 'file name for event';
is $c->_get_buffers_path(1), $c->_get_buffers_path($c->buffer_size + 1),
  'circular events buffer';
my $idx = $c->_write_event(my_event => (some => {data => 'is sent'}));
is $c->_read_event($idx),
  {i => $idx, e => 'my_event', a => [some => {data => 'is sent'}]},
  'read event';
my @errors;
$c->on(error => sub { push @errors, pop });
is $c->_read_event($idx + $c->buffer_size),
  {i => $idx, e => 'my_event', a => [some => {data => 'is sent'}]},
  'read with overflow';
is [@errors], ["Overflow trying to get event " . ($idx + $c->buffer_size)],
  "right overflow error";
my @evs;
$c->sender_counter(0)->receiver_counter(0);
$c->on(
  test1 => sub {
    my $self = shift;
    push @evs, [@_];
  }
);
$c->iemit(test1 => (alpha => '⍺'));

Mojo::IOLoop->recurring(
  0 => sub {
    my $loop = shift;
    Mojo::IOLoop->stop if $c->sender_counter == 1 && $c->receiver_counter == 0;
  }
);
Mojo::IOLoop->start;
is \@evs, [[alpha => '⍺']], 'got event';

# check unique event name
my $uniquec1 = $c->unique;
my $uniquec2 = $c->unique;
my $d        = Mojo::Iutils->new;
Mojo::IOLoop->start;
my $uniqued1 = $d->unique;

like $uniquec1, qr/^__\d+_\d+$/, "right unique format";
isnt $uniquec1, $uniquec2, "uniqs are different";
isnt $uniquec1, $uniqued1, "different objects unique differ";

my @unique_evs;
$c->sender_counter(0)->receiver_counter(0);
$c->on(
  $uniquec1 => sub {
    my $self = shift;
    push @unique_evs, [@_];
  }
);
$d->iemit($uniquec1 => (beta => 'β'));
Mojo::IOLoop->recurring(
  0 => sub {
    shift->stop if !$c->sender_counter && $c->receiver_counter;
  }
);
Mojo::IOLoop->start;
is \@unique_evs, [[beta => 'β']], 'got unique event';

done_testing;
