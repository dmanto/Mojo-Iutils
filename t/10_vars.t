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

# now checks expired vars
$Mojo::Iutils::FTIME = my $tbase = time;
is $c->istash(my_string => 'anything', expire => $tbase + 10), 'anything', 'writes with expire';
is $c->istash('my_string'), 'anything', 'reads with expire';
$Mojo::Iutils::FTIME = $tbase + 9;
is $c->istash('my_string'), 'anything', 'reads before expire';
$Mojo::Iutils::FTIME = $tbase + 11;
is $c->istash('my_string'), undef, 'reads after expire';

# now checks when to delete key files
$tbase += 100; # new base
$Mojo::Iutils::FTIME = $tbase;

$c->istash(my_string => 'anything'); # permanent
$Mojo::Iutils::FTIME = $tbase + Mojo::Iutils::CATCH_VALID_TO - 1; # before cache expires
is $c->istash('my_string'), 'anything', 'reads before cache expires';
$c->istash(my_string => undef); # deletes
is $c->istash('my_string'), undef, 'reads deleted before cache expires';
ok -f $c->_get_vars_path('my_string'), 'file still there before cache expires';
$Mojo::Iutils::FTIME = $tbase + Mojo::Iutils::CATCH_VALID_TO + 1; # on tolerance window
is $c->istash('my_string'), undef, 'reads deleted after cache expires';
ok -f $c->_get_vars_path('my_string'), 'file still there after cache expires';
$Mojo::Iutils::FTIME = $tbase + Mojo::Iutils::CATCH_VALID_TO + Mojo::Iutils::CATCH_SAFE_WINDOW + 1; # after tolerance window
is $c->istash('my_string'), undef, 'reads deleted after cache & tolerance window expires';
ok !-f $c->_get_vars_path('my_string'), 'file no longer there after cache & tolerance window expires';

done_testing;
