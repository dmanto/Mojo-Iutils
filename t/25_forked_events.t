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
use Data::Dumper;

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
  my $kind   = $m->server->port ? 'server' : 'client';
  my $unique = $m->unique;                               # get unique event name
  say STDERR "PID $$ ($kind), ya inicializo M::I, unique: $unique, cliente: "
    . ($m->client->connected // 'no conectado') . " "
    . $m->{_server_port};
  my $r_id = Mojo::IOLoop->recurring(
    .1 => sub {
      $m->iemit(test => {ans => $unique, type => $kind}) if $m->running;
      my $lid = $m->{_last_ievents_id};
      say STDERR "PID $$ ($kind), envio al main evento $unique, last_id $lid";
    }
  );
  $m->on(
    $unique => sub {
      shift;
      push @evs, @_;
      say STDERR "PID $$, recibio evento $unique";
      Mojo::IOLoop->remove($r_id);
      Mojo::IOLoop->stop;
    }
  );

  my $end = 0;
  Mojo::IOLoop->timer(30 => sub { $end = 1; shift->stop });
  Mojo::IOLoop->start;
  Mojo::IOLoop->timer(1 => sub { shift->stop });
  Mojo::IOLoop->start;
  exit($end);
}

# after all childs forked, it is safe to use DBD::SQLite in parent
my %received;
my $received_server;
my $m = Mojo::Iutils->new;
say STDERR "Proceso main, PID $$, ya inicializo M::I, cliente: "
  . ($m->client->connected // 'no conectado');
$m->on(
  test => sub {
    shift;
    my $args = shift;
    my $ans  = $args->{ans};    #
    my $kind = $args->{type};
    if ($kind =~ /client/) {
      $received{$ans}++;
      $m->iemit($ans => 'Ok');
      say STDERR "Main $$, emitio a cliente $ans, numero: " . $received{$ans};
    }
    elsif ($kind =~ /server/) {
      $received{$ans}++;
      $received_server = $ans;
      say STDERR "Main $$, guardo $ans como server";
    }
    else {
      say STDERR "Main $$, recibio evento desconocido";
    }
    if (keys %received >= $cforks && $received_server) {
      $m->iemit($received_server => 'Ok');
      say STDERR "Main $$, emitio a server $received_server";
      Mojo::IOLoop->stop;
    }
  }
);

Mojo::IOLoop->timer(10 => sub { shift->stop });
Mojo::IOLoop->start;
Mojo::IOLoop->timer(1 => sub { shift->stop });
Mojo::IOLoop->one_tick;

say STDERR "\n------\n" . (Dumper \%received);

wait();

is scalar keys %received, $cforks, "events received";
done_testing;
