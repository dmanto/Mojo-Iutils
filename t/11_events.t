BEGIN {
	$ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;
use Test2::V0;
use Mojo::Iutils;
use Mojo::File 'path';

$ENV{MOJO_MODE} = 'test';

my $c = Mojo::Iutils->new;
Mojo::IOLoop->next_tick(sub {$c->server_port and Mojo::IOLoop->stop});
Mojo::IOLoop->start;
is eval {$c->_get_events_path("NaN")}, undef, "should be a number";
like $c->_get_events_path(1), qr/E0000001$/, 'file name for event';
is $c->_get_events_path(1), $c->_get_events_path($c->events_queue_size + 1), 'circular events buffer';
my $idx = $c->_write_event(my_event => (some => {data => 'is sent'}));
is $c->_read_event($idx), {i => $idx, e => 'my_event', a => [some => {data => 'is sent'}]}, 'read event';
my @errors;
$c->on(error => sub {push @errors, pop});
is $c->_read_event($idx + $c->events_queue_size), {i => $idx, e => 'my_event', a => [some => {data => 'is sent'}]}, 'read with overflow';
is [@errors], ["Overflow trying to get event ". ($idx + $c->events_queue_size)], "right overflow error";
my (@evsc, @evsd);
$c->on(
	test1 => sub {
		shift;
		push @evsc, [@_];
		say STDERR '----> detiene el ioloop (push c)';
		Mojo::IOLoop->stop_gracefully;
	}
);
$c->iemit(test1 => (alpha => '⍺'));
Mojo::IOLoop->start;
is [@evsc], [[alpha => '⍺']], 'got event';

$c->on(
	test1 => sub {
		shift;
		push @evsd, [@_];
		say STDERR '----> detiene el ioloop (push d)';
		Mojo::IOLoop->stop_gracefully;
	}
);
$c->iemit(test1 => (beta => 'β', gamma => {uc => 'Γ', lc => 'γ'}));
Mojo::IOLoop->start;
is [@evsc], [[alpha => '⍺'], [beta => 'β', gamma => {uc => 'Γ', lc => 'γ'}]], 'got 2 events';
is [@evsd], [[beta => 'β', gamma => {uc => 'Γ', lc => 'γ'}]], 'just 2nd event';
done_testing;
