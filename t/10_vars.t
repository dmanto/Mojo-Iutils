BEGIN {
	$ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;
use Test2::V0;
use Mojo::Iutils;
use Mojo::File 'path';

$ENV{MOJO_MODE} = 'test';

my $c = Mojo::Iutils->new;
is eval {$c->_get_vars_path("wrong\tpath")}, undef, "wrong key";

# scalar arguments and contexts
is $c->istash(my_string => 'something'), 'something', 'writes';
is $c->istash('my_string'), 'something', 'reads';
is $c->istash(my_string => sub {uc shift}), 'SOMETHING', 'modifies';
is $c->istash('my_string'), 'SOMETHING', 'reads modified';
is $c->istash(my_string => 'smth'), 'smth', 'shorter';
is $c->istash('my_string'), 'smth', 'reads shorter';
is $c->istash(my_string => 'Mojo 8.0 (🦹)'), 'Mojo 8.0 (🦹)', 'writes utf-8';
is $c->istash('my_string'), 'Mojo 8.0 (🦹)', 'reads utf-8';
is $c->istash(my_string => undef), undef, 'deletes';
is $c->istash('my_string'), undef, 'reads deleted';
is $c->istash(my_counter => ''), '', 'resets counter';
is $c->istash(my_counter => sub {++$_}), 1, 'increments counter';
is $c->istash(my_counter => sub {++$_}), 2, 'increments counter twice';

# list arguments and contexts
is [$c->istash(my_array => (qw{alfa beta gamma}))], [qw{alfa beta gamma}], 'writes array';
is [$c->istash('my_array')], [qw{alfa beta gamma}], 'reads array';
is {
	$c->istash(
		my_array => sub {
			map {$_ => undef} @_;
		}
	  )
}, {alfa => undef, beta => undef, gamma => undef}, 'modifies array';
is {
	$c->istash('my_array')
}, {alfa => undef, beta => undef, gamma => undef}, 'reads modified array';

done_testing;
