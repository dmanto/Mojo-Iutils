use Mojo::Base -strict;
use Mojo::IOLoop;
use Time::HiRes 'time';

my $id = Mojo::IOLoop->client(
	{port => 3000} => sub {
		my ($loop, $err, $stream) = @_;
        say $err and return unless $stream;
		$stream->on(
			read => sub {
				my ($stream, $bytes) = @_;

				# Process input
				say "Input: $bytes";
                # $stream->close;
			}
		);

		# Write request
		$stream->write("GET / HTTP/1.1\x0d\x0a\x0d\x0a");
        $stream->timeout(0);
	}
);

my $idr;
$idr = Mojo::IOLoop->recurring(
	.5 => sub {
		my $loop = shift;
		state $count = 1;
		say "No bloquea, $count, tiempo: ".time;
		$loop->remove($idr) if $count > 10;
		$count++;
	}
);

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;