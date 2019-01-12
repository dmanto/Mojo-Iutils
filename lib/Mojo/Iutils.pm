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
	MAGIC_ID => 'IUTILS_MAGIC_str'
};

has base_dir => sub {
	my $mode = shift->app_mode // $ENV{MOJO_MODE};
	my $p = path(tmpdir, IUTILS_DIR . (eval {scalar getpwuid($<)} || getlogin || 'nobody'));
	return ($mode ? $p->child($mode) : $p)->to_string;
};

has buffer_size => sub {512};

our $VERSION = '0.01';
has [qw(app_mode varsdir buffersdir vars_semaphore buffers_semaphore server_port sender_counter receiver_counter)];
has 'valid_fname' => sub {qr/^[\w\.-]+$/};
has catched_vars => sub {{}};
has enc => sub {shift->{_enc} //= Sereal::Encoder->new};
has dec => sub {shift->{_dec} //= Sereal::Decoder->new};


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


sub istash {
	my ($self, $key, @set_list) = @_;
	my @val_list;
	my $cb = $set_list[0] if ref $set_list[0] eq 'CODE';
	my $has_to_write = 1 if @set_list;
	undef @set_list if $cb;
	my $has_to_read = !@set_list;

	unless (exists $self->catched_vars->{$key}) {
		my $file = $self->_get_vars_path($key);
		open(my $sf, '>', $self->vars_semaphore) or die "Couldn't open $self->vars_semaphore for write: $!";
		flock($sf, LOCK_EX) or die "Couldn't lock $self->vars_semaphore: $!";
		unless (-f $file){
			open my $tch, '>', $file or die "Couldn't touch $file: $!";
			close($tch) or die "Couldn't close $file: $!";
		}
		close($sf) or die "Couldn't close $self->vars_semaphore: $!";
		$self->catched_vars->{$key} = $file;
	}
	my $fname = $self->catched_vars->{$key}; # path to file
	my $lock_flags = $has_to_write ? LOCK_EX : LOCK_SH;
	my $old_length;
	open my $fh, '+<', $fname or die "Couldn't open $fname: $!";
	binmode $fh;
	flock($fh, $lock_flags) or die "Couldn't lock $fname: $!";
	if ($has_to_read) {
		my $slurped_file = do {local $/; <$fh>};
		if ($old_length = length $slurped_file) {
			my ($type, $val) = unpack('a1a*', $slurped_file);
			if ($type eq '=') {
				@val_list = ($val);
			} elsif ($type eq 'U') {
				@val_list = decode('UTF-8', $val);
			} elsif ($type eq ':') {
				@val_list = @{sereal_decode_with_object $self->dec, $val};
			} else {
				die "Unreconized file content: $type$val";
			}
		} # else keeps @val_list as an empty array
	}
	@set_list = $cb->(@val_list) if $cb;
	if ($has_to_write) {
		my $to_print;
		if (@set_list == 1 && defined $set_list[0]) {
			my $val = $set_list[0];
			my ($type, $enc_val);
			if (utf8::is_utf8($val)) {$type='U';$enc_val = encode 'UTF-8', $val}
			else {$type = '='; $enc_val = $val}
			$to_print = pack 'a1a*', $type, $enc_val;
		} elsif (@set_list >= 1) {
			$to_print = pack 'a1a*', ':', sereal_encode_with_object($self->enc, \@set_list );
		} else { # set_list is an empty array
			$to_print = '';
		}

		seek $fh, 0, 0;
		print $fh ($to_print);
		my $new_length = length($to_print);
		truncate $fh, $new_length if !defined $old_length || $old_length > $new_length;
	}

	close($fh) or die "Couldn't close $fname: $!";
	my @ret_val = $has_to_write ? @set_list : @val_list;
	return wantarray ? @ret_val : $ret_val[-1];
}


sub new {
	return shift->SUPER::new(@_)->_init();
}


sub iemit {
	my ($self, $event) = (shift, shift);
	my @args = @_;
	my @ports;

	my $idx;
	if ($event =~ /^__(\d+)_\d+$/) { # unique send
		@ports = ($1);
	} else {
		@ports = split /:/, ($self->istash('__ports') // '');
	}
	for my $p (@ports) {
		if ($p == $self->server_port) { # no need to send
			 # print STDERR "Emitira localmente $event, (puerto $p)";
			 # say STDERR $self->{events}{$event} ? ' (agendado)' : '';

			# CAVEAT $self->{events} hash not docummented in Mojo::EE
			$self->emit($event, @args) if $self->{events}{$event};
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
				if ($stream) {

					# say STDERR sprintf "Se conecto desde %d al %d", $self->server_port, $p;
					$stream->on(
						error => sub {
							my ($stream, $err) = @_;
							$self->_delete_port($p);

							# say STDERR "error $err, deberia borrar ${\$id}";
							$loop->remove($id);
						}
					);
					$stream->on(
						close => sub {
							$loop->remove($id);
						}
					);
					$stream->on(
						read => sub {
							my ($stream, $bytes) = @_;
							say STDERR "Port $p recibio: $bytes";
						}
					);
					$stream->write($idx => sub {shift->close});

					# say STDERR "Ya escribio en $p";
				} else {
					$self->_delete_port($p);

					# say STDERR "Deberia borrar ${\$id}, no encontro $p";
					$loop->remove($id);
				}
			}
		);

		# say STDERR "Ya instalo $p, busca siguiente";
	}
	$self->{sender_counter}++;
}


sub _init {
	my ($self) = @_;

	# first thing to do, define broker msg server
	my $id = Mojo::IOLoop->server(
		{address => '127.0.0.1'} => sub {
			my ($loop, $stream, $id) = @_;

			# say STDERR '===> se estan conectando al puerto ', $self->server_port;
			$stream->on(
				read => sub {
					my ($stream, $bytes) = @_;

					# say STDERR "$$: en port ${\$self->server_port} recibio: $bytes";

					# $stream->write(
					# 	MAGIC_ID() => sub {
					# 		shift->close;
					# 	}
					# );
					return unless $bytes && $bytes =~ /^(\d+)$/;
					my $res = $self->_read_event($1);
					my $event = $res->{e};
					my @args = @{$res->{a}};

					# print STDERR "Emitira $event recibido";
					# say STDERR $self->{events}{$event} ? ' (agendado)' : '';

					# CAVEAT $self->{events} hash not docummented in Mojo::EE
					$self->emit($event, @args) if $self->{events}{$event};
					$self->{receiver_counter}++;
				}
			);
		}
	);

	$self->server_port(Mojo::IOLoop->acceptor($id)->port);
	$self->istash(
		__ports => sub {
			my %ports = map {$_ => undef} split /:/, (shift // '');
			undef $ports{$self->server_port};
			return join ':', keys %ports;
		}
	);

	# say STDERR "Server port: ${\$self->server_port}";
	return $self;
}


sub _delete_port {
	my ($self, $p) = @_;
	$self->istash(
		__ports => sub {
			my %ports = map {$_ => undef} split /:/, (shift // '');
			delete $ports{$p};
			return join ':', keys %ports;
		}
	);
}


sub DESTROY {
	my $self = shift;
	$self->_delete_port($self->server_port);
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

