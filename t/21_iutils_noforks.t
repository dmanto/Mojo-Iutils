use strict;
use warnings;
use utf8;

BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use Test::More;
use Mojo::Iutils;

$ENV{MOJO_MODE}        = 'test';
$ENV{MOJO_IUTILS_NAME} = 'mojotest';

my $m1 = Mojo::Iutils->new;
my $m2 = Mojo::Iutils->new;

my @evs;

$m2->on(
  ev1 => sub {
    my ($e, @args) = @_;
    push @evs, @args;
  }
);

$m1->iemit(ev1 => 123, 456);


my $end = 0;
my $tid = Mojo::IOLoop->timer(1 => sub { $end = 1; shift->stop });
Mojo::IOLoop->one_tick while !(@evs || $end);
Mojo::IOLoop->remove($tid);

is_deeply \@evs, [123, 456], "right event";

done_testing;
