use strict;
use warnings;


BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use utf8;

use Test2::IPC;
use Test2::V0;
use Mojo::Iutils;
use Mojo::File 'path';
use Time::HiRes qw /sleep time/;

$ENV{MOJO_MODE} = 'test';

my $c = Mojo::Iutils->new;
Mojo::IOLoop->timer(0.05 => sub { shift->stop });
Mojo::IOLoop->start;
$c->istash(sync => undef);
my $cforks = 40;
$c->istash("sal$_" => undef) for 1 .. $cforks;

for my $nfork (1 .. $cforks) {
  die "fork: $!" unless defined(my $pid = fork);
  next if $pid;

  # childs
  # NO tests inside child code pls
  my @evs;
  my $m = Mojo::Iutils->new;
  Mojo::IOLoop->timer(.05 => sub { shift->stop });
  Mojo::IOLoop->start;
  $m->sender_counter(0)->receiver_counter(0);
  $m->on(
    test1 => sub {
      shift;
      push @evs, @_;
    }
  );
  my $nv = $m->istash(sync => sub { ++$_[0] });

  # say STDERR "From child # $nfork, waiting sync 1, nv is $nv";
  while ($m->istash('sync') < $cforks) {
    sleep .05;    # be nice with other kids
  }

  # say STDERR "From child # $nfork, sync 1 pased, my nv was $nv";
  $m->iemit(test1 => "from child # $nfork");
  Mojo::IOLoop->recurring(
    1 => sub {
      my $loop = shift;
    #   my $line
    #     = "$$:Counters: "
    #     . $m->sender_counter . ' '
    #     . $m->receiver_counter . ' - ';
    #   say STDERR $line;
      Mojo::IOLoop->stop
        if $m->sender_counter == 1 && $m->receiver_counter == ($cforks - 1);
    }
  );
  Mojo::IOLoop->start;
  my $sync = $m->istash(sync => sub { ++$_[0] });
#   say STDERR "$$: incremento sync a $sync";
  while ($m->istash('sync') < 2 * $cforks) {
    sleep .05;    # same as before
  }
  $m->istash("sal$nfork" => join(':', @evs));
  sleep .05;
  exit(0);
}
wait();
is $c->istash('sync'), 2 * $cforks, 'sync';
my @end_result;
push @end_result, sprintf "from child # $_"
  for sort 1 .. $cforks;    # alfanumeric sort (i.e. 10 < 2)
is [sort split(':', $c->istash("sal1"))], \@end_result, 'child #1 events';
$c->DESTROY;
done_testing;
