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

$ENV{MOJO_MODE} = 'test';

my $c = Mojo::Iutils->new;
$c->istash(sync => undef);
my $cforks = 2;
$c->istash("sal$_" => undef) for 1..$cforks;

for my $nfork (1..$cforks) {
	die "fork: $!" unless defined(my $pid = fork);
	next if $pid;

	# childs
	# NO tests inside child code pls
	my @evs;
	my $m = Mojo::Iutils->new;
	$m->sender_counter(0)->receiver_counter(0);
	$m->on(
		test1 => sub {
			shift;
			push @evs, @_;

			# Mojo::IOLoop->next_tick(sub {shift->stop});
		}
	);
	$m->istash(sync => sub {++$_[0]});
	say STDERR "From child # $nfork, waiting sync 1";
	while ($m->istash('sync') < $cforks) {}

	$m->iemit(test1 => "from child # $nfork");
	Mojo::IOLoop->recurring(
		0 => sub {
			my $loop = shift;
			my $line = "$$:Counters: " . $m->sender_counter . ' ' . $m->receiver_counter . ' - ';
			say STDERR $line;
			$m->sender_counter == 1 && $m->receiver_counter == 1 && Mojo::IOLoop->stop;
		}
	);
	Mojo::IOLoop->start;
	$m->istash(sync => sub {++$_[0]});
	say STDERR "From child # $nfork, waiting sync 2";
	while ($m->istash('sync') < 2 * $cforks) {}
	$m->istash("sal$nfork" => join(':', @evs));
	exit(0);
}

wait();
is $c->istash('sync'), 2 * $cforks, 'sync';
is $c->istash("sal1"), "from child # 1:from child # 2", 'child #1 events';
done_testing;
