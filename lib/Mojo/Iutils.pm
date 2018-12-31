package Mojo::Iutils;
use Mojo::Base 'Mojo::EventEmitter';
use Carp 'croak';
use Fcntl ':flock';
use File::Spec::Functions 'tmpdir';
use Mojo::IOLoop;
use Mojo::File 'path';
use Mojo::Util;
use Encode qw/decode encode/;
use Sereal qw {sereal_encode_with_object sereal_decode_with_object};
use constant {
	IUTILS_DIR => 'mojo_iutils_',
	DEBUG => $ENV{MOJO_IUTILS_DEBUG} || 0,
	VARS_DIR => 'vars',
	LOCKS_DIR => 'locks',
	PUBSUBS_DIR => 'pubsubs',
	QUEUES_DIR => 'queues',
	EVENTS_DIR => 'events',
	CATCH_VALID_TO => 5,
	CATCH_SAFE_WINDOW => 5
};

has base_dir => sub {
	path(tmpdir, IUTILS_DIR.(eval {scalar getpwuid($<)} || getlogin || 'nobody'))->to_string;
};

has events_queue_size => sub {64};

our $VERSION = '0.01';
our $FTIME; # Fake time, for testing only
my ($varsdir, $queuesdir, $pubsubsdir, $eventsdir, $vars_semaphore, $events_semaphore);
my $valid_fname = qr/^[\w\.-]+$/;
my $enc = Sereal::Encoder->new;
my $dec = Sereal::Decoder->new;
my %catched_vars;


sub _get_vars_path {
	my ($self, $key) = @_;
	die "Key $key not valid" unless $key =~ $valid_fname;
	unless ($varsdir) { # inicializes $varsdir & $vars_semaphore
		$varsdir = path($self->base_dir, VARS_DIR );
		$varsdir->make_path unless -d $varsdir;
		$vars_semaphore = $varsdir->sibling('vars.lock')->to_string;
	}
	return $varsdir->child($key)->to_string;
}


sub _get_events_path {
	my ($self, $n) = @_;
	die "Emit ID $n not valid" unless $n =~ /^\d+$/; # only integers are valid
	unless ($eventsdir) { # inicializes $eventsdir & $events_semaphore
		$eventsdir = path($self->base_dir, EVENTS_DIR );
		$eventsdir->make_path unless -d $eventsdir;
		$events_semaphore = $eventsdir->sibling('events.lock')->to_string;
	}
	return $eventsdir->child(sprintf 'E%07d', $n % $self->events_queue_size)->to_string;
}


sub _write_event {
	my ($self, $event, @args) = @_;
	my $idx = $self->istash(__events_idx => sub {++$_[0]});
	my $fname = _get_events_path($self, $idx);
	my $bytes = sereal_encode_with_object $enc, {i => $idx, e => $event, a => \@args};
	open my $wev, '>', $fname or die "Couldn't open event file: $!";
	binmode $wev;
	flock($wev, LOCK_EX) or die "Couldn't lock $fname: $!";
	print $wev $bytes;
	close($wev) or die "Couldn't close $fname: $!";
	return $idx;
}


sub _read_event {
	my ($self, $idx) = @_;
	my $fname = _get_events_path($self,$idx);
	open my $rev, '<', $fname or die "Couldn't open event file: $!";
	binmode $rev;
	flock($rev, LOCK_SH) or die "Couldn't lock $fname: $!";
	my $bytes = do {local $/; <$rev>};
	close($rev) or die "Couldn't close $fname: $!";
	my $res = sereal_decode_with_object $dec, $bytes;
	$self->emit(error => "Overflow trying to get event $idx") unless $res->{i} == $idx;
	return $res;
}


sub ikeys {
	my $self = shift;
	$self->_get_vars_path('dummy') unless $varsdir; # initializes $varsdir
	return $varsdir->list->map('basename')->to_array;
}


sub gc {
	my $self = shift;
	$self->istash($_) for @{$self->ikeys};
	my $ctime = sprintf '%10d', $FTIME // time; # current time, 10 digits number
	for my $key (keys %catched_vars) {
		delete $catched_vars{$key} unless $ctime <= $catched_vars{$key}{tstamp} + CATCH_VALID_TO;
	}
	return $self;
}


sub istash {
	my ($self, $key, $arg, %opts) = @_;
	my ($cb, $val, $set_val, $last_def, $expires_by, $type);
	my $ctime = sprintf '%10d', $FTIME // time; # current time, 10 digits number
	$cb = $arg if ref $arg eq 'CODE';
	my $has_to_write = @_ % 2; # odd nmbr of arguments --> write
	$set_val = $arg unless $cb or !$has_to_write;

	unless (exists $catched_vars{$key} && $ctime <= $catched_vars{$key}{tstamp} + CATCH_VALID_TO) {
		my $file = $self->_get_vars_path($key);
		open(my $sf, '>', $vars_semaphore) or die "Couldn't open $vars_semaphore for write: $!";
		flock($sf, LOCK_EX) or die "Couldn't lock $vars_semaphore: $!";
		unless (-f $file){
			open my $tch, '>', $file or die "Couldn't touch $file: $!";
			close($tch) or die "Couldn't close $file: $!";
		}
		close($sf) or die "Couldn't close $vars_semaphore: $!";
		$catched_vars{$key}{path} = $file;
	}


	my $fname = $catched_vars{$key}{path}; # path to file
	my $lock_flags = $has_to_write ? LOCK_EX : LOCK_SH;
	my $old_length;
	open my $fh, '+<', $fname or die "Couldn't open $fname: $!";
	binmode $fh;
	flock($fh, $lock_flags) or die "Couldn't lock $fname: $!";
	my $slurped_file = do {local $/; <$fh>};
	$old_length = length $slurped_file;
	($last_def, $expires_by, $type, $val) = unpack('a10a10a1a*', $slurped_file);

	if ($last_def && $expires_by && $expires_by gt $ctime) {
		$val = decode('UTF-8', $val) if $type && $type eq 1;
	} else {
		undef $val;
	}
	if ($has_to_write) {
		$val = $cb ? $cb->($val) : $set_val;

		my $to_print;
		my $expires_set = sprintf '%10d', $opts{expire} // 9999999999;
		undef $val if $ctime >= $expires_set;
		if (defined $val) {
			$catched_vars{$key}{tstamp} = $last_def = $ctime;
			my $enc_val;
			if (utf8::is_utf8($val)) {$type=1;$enc_val = encode 'UTF-8', $val}
			else {$type = 0; $enc_val = $val}
			$to_print = pack 'a10a10a1a*', $last_def, $expires_set, $type, $enc_val;
		} else {
			$to_print = $last_def // '';
		}

		seek $fh, 0, 0;
		print $fh ($to_print);
		my $new_length = length($to_print);
		truncate $fh, $new_length if !defined $old_length || $old_length > $new_length;
	}

	close($fh) or die "Couldn't close $fname: $!";
	$last_def ||= 0;
	$catched_vars{$key}{tstamp} = $last_def;
	unless (defined $val || $ctime <= $last_def + CATCH_VALID_TO + CATCH_SAFE_WINDOW) {
		open(my $sf, '>', $vars_semaphore) or die "Couldn't open $vars_semaphore for write: $!";
		flock($sf, LOCK_EX) or die "Couldn't lock $vars_semaphore: $!";
		unlink $fname if -f $fname;
		close($sf) or die "Couldn't close $vars_semaphore: $!";
	}
	return $val;
}


sub new {
	my $class = shift->SUPER::new(@_);
	Mojo::IOLoop->next_tick(\&_init($class));
	return $class;
}


sub _bcast {
	my ($self, $msg, @ports) = @_;
	for my $p (@ports) {
		my $id;
		$id = Mojo::IOLoop::client(
			{
				address => '127.0.0.1',
				port => $p
			} => sub {
				my ($loop, $err, $stream) = @_;
				if ($stream) {
					$stream->on(error => sub {});
					$stream->on(close => sub {$loop->remove($id)});
					$stream->write($msg);
				} else {
					$self->istash(
						__ports => sub {
							my %ports = map {$_ => undef} split /:/, (shift // '');
							delete $ports{$p};
							return join ':', keys %ports;
						}
					);
					$loop->remove($id);
				}
			}
		);
	}
}


sub _init {
	my ($self) = @_;

	# first thing to do, define broker msg server
	my $port;
	my $id = Mojo::IOLoop->server(
		{address => '127.0.0.1'} => sub {
			my ($loop, $stream, $id) = @_;
			$stream->on(
				read => sub {
					my ($stream, $bytes) = @_;

					# say "$$: en port $port recibio: $bytes";
					$stream->write(
						"$$: $port $bytes" => sub {
							shift->close if $bytes =~ /FIN/;
						}
					);
				}
			);
		}
	);

	$port = Mojo::IOLoop->acceptor($id)->port;
	$self->istash(
		__ports => sub {
			my %ports = map {$_ => undef} split /:/, (shift // '');
			undef $ports{$port};
			return join ':', keys %ports;
		}
	);
}

1;
__END__

=encoding utf-8

=head1 NAME

Mojo::Iutils - It's new $module

=head1 SYNOPSIS

    use Mojo::Iutils;

=head1 DESCRIPTION

Mojo::Iutils is ...

=head1 LICENSE

Copyright (C) Daniel Mantovani.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Daniel Mantovani E<lt>daniel@gmail.comE<gt>

=cut

