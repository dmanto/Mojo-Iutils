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
	BUFFERS_DIR => 'buffers',
	CATCH_VALID_TO => 5,
	CATCH_SAFE_WINDOW => 5,
	MAGIC_ID => 'IUTILS_MAGIC_str'
};

has base_dir => sub {
	my $mode = shift->app_mode // $ENV{MOJO_MODE};
	my $p = path(tmpdir, IUTILS_DIR . (eval {scalar getpwuid($<)} || getlogin || 'nobody'));
	return ($mode ? $p->child($mode) : $p)->to_string;
};

has buffer_size => sub {64};

our $VERSION = '0.01';
our $FTIME; # Fake time, for testing only
has [qw(app_mode varsdir buffersdir vars_semaphore buffers_semaphore server_port)];
has 'valid_fname' => sub {qr/^[\w\.-]+$/};
has enc => sub {state $s = Sereal::Encoder->new};
has dec => sub {state $s = Sereal::Decoder->new};
has catched_vars => sub {{}};


sub _get_vars_path {
	my ($self, $key) = @_;
	die "Key $key not valid" unless $key =~ $self->valid_fname;
	unless ($self->varsdir) { # inicializes $self->varsdir & $self->vars_semaphore
		$self->varsdir(path($self->base_dir, VARS_DIR ));
		$self->varsdir->make_path unless -d $self->varsdir;
		$self->vars_semaphore($self->varsdir->sibling('vars.lock')->to_string);
	}
	return $self->varsdir->child($key)->to_string;
}


sub _get_buffers_path {
	my ($self, $n) = @_;
	die "Emit ID $n not valid" unless $n =~ /^\d+$/; # only integers are valid
	unless ($self->buffersdir) { # inicializes $self->buffersdir & $self->buffers_semaphore
		$self->buffersdir(path($self->base_dir, BUFFERS_DIR ));
		$self->buffersdir->make_path unless -d $self->buffersdir;
		$self->buffers_semaphore($self->buffersdir->sibling('buffers.lock')->to_string);
	}
	return $self->buffersdir->child(sprintf 'E%07d', $n % $self->buffer_size)->to_string;
}


sub _write_event {
	my ($self, $event, @args) = @_;
	my $idx = $self->istash(__buffers_idx => sub {++$_[0]});
	my $fname = _get_buffers_path($self, $idx);
	my $bytes = sereal_encode_with_object $self->enc, {i => $idx, e => $event, a => \@args};
	open my $wev, '>', $fname or die "Couldn't open event file: $!";
	binmode $wev;
	flock($wev, LOCK_EX) or die "Couldn't lock $fname: $!";
	print $wev $bytes;
	close($wev) or die "Couldn't close $fname: $!";
	return $idx;
}


sub _read_event {
	my ($self, $idx) = @_;
	my $fname = _get_buffers_path($self,$idx);
	open my $rev, '<', $fname or die "Couldn't open event file: $!";
	binmode $rev;
	flock($rev, LOCK_SH) or die "Couldn't lock $fname: $!";
	my $bytes = do {local $/; <$rev>};
	close($rev) or die "Couldn't close $fname: $!";
	my $res = sereal_decode_with_object $self->dec, $bytes;
	$self->emit(error => "Overflow trying to get event $idx") unless $res->{i} == $idx;
	return $res;
}


sub ikeys {
	my $self = shift;
	$self->_get_vars_path('dummy') unless $self->varsdir; # initializes $self->varsdir
	return $self->varsdir->list->map('basename')->to_array;
}


sub gc {
	my $self = shift;
	$self->istash($_) for @{$self->ikeys};
	my $ctime = sprintf '%10d', $FTIME // time; # current time, 10 digits number
	for my $key (keys %{$self->catched_vars}) {
		delete $self->catched_vars->{$key} unless $ctime <= $self->catched_vars->{$key}{tstamp} + CATCH_VALID_TO;
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

	unless (exists $self->catched_vars->{$key} && $ctime <= $self->catched_vars->{$key}{tstamp} + CATCH_VALID_TO) {
		my $file = $self->_get_vars_path($key);
		open(my $sf, '>', $self->vars_semaphore) or die "Couldn't open $self->vars_semaphore for write: $!";
		flock($sf, LOCK_EX) or die "Couldn't lock $self->vars_semaphore: $!";
		unless (-f $file){
			open my $tch, '>', $file or die "Couldn't touch $file: $!";
			close($tch) or die "Couldn't close $file: $!";
		}
		close($sf) or die "Couldn't close $self->vars_semaphore: $!";
		$self->catched_vars->{$key}{path} = $file;
	}


	my $fname = $self->catched_vars->{$key}{path}; # path to file
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
			$self->catched_vars->{$key}{tstamp} = $last_def = $ctime;
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
	$self->catched_vars->{$key}{tstamp} = $last_def;
	unless (defined $val || $ctime <= $last_def + CATCH_VALID_TO + CATCH_SAFE_WINDOW) {
		open(my $sf, '>', $self->vars_semaphore) or die "Couldn't open $self->vars_semaphore for write: $!";
		flock($sf, LOCK_EX) or die "Couldn't lock $self->vars_semaphore: $!";
		unlink $fname if -f $fname;
		close($sf) or die "Couldn't close $self->vars_semaphore: $!";
	}
	return $val;
}


sub new {
	return shift->SUPER::new(@_)->_init();
}


sub iemit {
	my ($self, $event) = (shift, shift);
	my @args = @_;
	my @ports;

	my $cant;
	my $idx;
	if ($event =~ /^__(\d+)_\d+$/) { # unique send
		@ports = ($1);
	} else {
		@ports = split /:/, ($self->istash('__ports') // '');
	}
	for my $p (@ports) {

		$cant++;

		# say STDERR "Con port $p, cant: $cant";
		if ($p == $self->server_port) { # no need to send
			print STDERR "Emitira localmente $event, (puerto $p)";
			say STDERR $self->{events}{$event} ? ' (agendado)' : '';

			# CAVEAT $self->{events} hash not docummented in Mojo::EE
			$self->emit($event, @args) if $self->{events}{$event};

			# --$cant or Mojo::IOLoop->stop;
			next;
		}
		$idx //= $self->_write_event($event => @args);
		my $id;
		$id = Mojo::IOLoop->client(
			{
				address => '127.0.0.1',
				port => $p
			} => sub {
				my ($loop, $err, $stream) = @_;
				say STDERR "Conexion o error en $p";
				if ($stream) {
					say STDERR sprintf "Se conecto desde %d al %d", $self->server_port, $p;
					$stream->on(
						error => sub {
							my ($stream, $err) = @_;
							$self->istash(
								__ports => sub {
									my %ports = map {$_ => undef} split /:/, (shift // '');
									delete $ports{$p};
									return join ':', keys %ports;
								}
							);
							say STDERR "error $err, deberia borrar ${\$id}";
							$loop->remove($id);

							# --$cant or $loop->stop;
						}
					);
					$stream->on(
						close => sub {
							$loop->remove($id)

							  #   ;--$cant or $loop->stop
						}
					);
					$stream->on(
						read => sub {
							my ($stream, $bytes) = @_;
							say STDERR "Port $p recibio: $bytes";
							++$self->{__handshakes_ok} if $bytes;
						}
					);
					$stream->write($idx);
					say STDERR "Ya escribio en $p";
				} else {
					$self->istash(
						__ports => sub {
							my %ports = map {$_ => undef} split /:/, (shift // '');
							delete $ports{$p};
							return join ':', keys %ports;
						}
					);
					say STDERR "Deberia borrar ${\$id}, no encontro $p";
					$loop->remove($id);

					# --$cant or $loop->stop;
				}
			}
		);
		say STDERR "Ya instalo $p, busca siguiente";
	}
}


sub _init {
	my ($self) = @_;

	# first thing to do, define broker msg server
	$self->{_iid} = Mojo::IOLoop->server(
		{address => '127.0.0.1'} => sub {
			my ($loop, $stream, $id) = @_;
			say STDERR '===> se estan conectando al puerto ', $self->server_port;
			$stream->on(
				read => sub {
					my ($stream, $bytes) = @_;

					say "$$: en port ${\$self->server_port} recibio: $bytes";
					$stream->write(
						MAGIC_ID() => sub {
							shift->close;
						}
					);
					return unless $bytes && $bytes =~ /^(\d+)$/;
					my $res = $self->_read_event($1);
					my $event = $res->{e};
					my @args = @{$res->{a}};
					print STDERR "Emitira $event recibido";
					say STDERR $self->{events}{$event} ? ' (agendado)' : '';

					# CAVEAT $self->{events} hash not docummented in Mojo::EE
					$self->emit($event, @args) if $self->{events}{$event};
				}
			);
		}
	);

	$self->server_port(Mojo::IOLoop->acceptor($self->{_iid})->port);
	$self->istash(
		__ports => sub {
			my %ports = map {$_ => undef} split /:/, (shift // '');
			undef $ports{$self->server_port};
			return join ':', keys %ports;
		}
	);
	say STDERR "Server port: ${\$self->server_port}";
	return $self;
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

