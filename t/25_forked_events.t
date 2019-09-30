use strict;
use warnings;
use utf8;

BEGIN {
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}
use Test2::IPC;
use Test2::V0;
use Mojo::Iutils;
use Mojo::File 'path';
use Time::HiRes qw /sleep time/;

$ENV{MOJO_MODE}        = 'test';
$ENV{MOJO_IUTILS_NAME} = 'mojotest';

my $cforks = 6;

for my $nfork (1 .. $cforks) {
  die "fork: $!" unless defined(my $pid = fork);
  next if $pid;

  # childs
  # NO tests inside child code pls
  my @evs;
  my $m      = Mojo::Iutils->new;
  my $unique = $m->unique;          # get unique event name
  say STDERR "PID $$, ya inicializo M::I, unique: $unique, cliente: "
    . ($m->client->connected // 'no conectado') . " "
    . $m->{_server_port};
  $m->on(
    $unique => sub {
      shift;
      push @evs, @_;
      say STDERR "PID $$, recibio evento $unique";
    }
  );
  my $r_id = Mojo::IOLoop->recurring(
    .5 => sub {
      $m->iemit(test => {ans => $unique});
      say STDERR "PID $$, envio al servidor evento $unique";
    }
  );

  my $end = 0;
  my $tid = Mojo::IOLoop->timer(30 => sub { $end = 1; shift->stop });
  Mojo::IOLoop->one_tick, sleep .01 while !(@evs || $end);
  Mojo::IOLoop->remove($tid);
  Mojo::IOLoop->remove($r_id);


  exit($end);
}

# after all childs forked, it is safe to use DBD::SQLite in parent
my %received;
my $m = Mojo::Iutils->new;
say STDERR "Proceso main, PID $$, ya inicializo M::I, cliente: "
  . ($m->client->connected // 'no conectado');
$m->on(
  test => sub {
    shift;
    my $ans = shift->{ans};    #
    $m->iemit($ans => 'Ok');
    $received{$ans}++;
    say STDERR "Main $$, emitio $ans, numero: " . $received{$ans};
  }
);
my $end = 0;
my $tid = Mojo::IOLoop->timer(10 => sub { $end = 1; shift->stop });
Mojo::IOLoop->one_tick, sleep .01 while !(keys %received >= $cforks || $end);
Mojo::IOLoop->remove($tid);

wait();

is scalar keys %received, $cforks, "events received";
done_testing;
