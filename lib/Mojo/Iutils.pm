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
  IUTILS_DIR  => 'mojo_iutils_',
  DEBUG       => $ENV{MOJO_IUTILS_DEBUG} || 0,
  VARS_DIR    => 'vars',
  BUFFERS_DIR => 'buffers',
};

has base_dir => sub {
  my $mode = shift->app_mode // $ENV{MOJO_MODE};
  my $p    = path(tmpdir,
    IUTILS_DIR . (eval { scalar getpwuid($<) } || getlogin || 'nobody'));
  return ($mode ? $p->child($mode) : $p)->to_string;
};

has buffer_size => sub {128};

our $VERSION = '0.01';
has [qw(app_mode sender_counter receiver_counter)];

sub _get_vars_path {
  my ($self, $key) = @_;
  die "Key $key not valid" unless $key =~ qr/^[\w\.-]+$/;
  unless ($self->{varsdir})
  {    # inicializes $self->{varsdir} & $self->{vars_semaphore}
    $self->{varsdir} = path($self->base_dir, VARS_DIR);
    $self->{varsdir}->make_path unless -d $self->{varsdir};
    $self->{vars_semaphore} = $self->{varsdir}->sibling('vars.lock')->to_string;
  }
  return $self->{varsdir}->child($key)->to_string;
}


sub _get_buffers_path {
  my ($self, $n) = @_;
  die "Emit ID $n not valid" unless $n =~ /^\d+$/;    # only integers are valid
  unless ($self->{buffersdir})
  {    # inicializes $self->{buffersdir} & $self->{buffers_semaphore}
    $self->{buffersdir} = path($self->base_dir, BUFFERS_DIR);
    $self->{buffersdir}->make_path unless -d $self->{buffersdir};
    $self->{buffers_semaphore}
      = $self->{buffersdir}->sibling('buffers.lock')->to_string;
  }
  return $self->{buffersdir}->child(sprintf 'E%07d', $n % $self->buffer_size)
    ->to_string;
}


sub _write_event {
  my ($self, $event, @args) = @_;
  my $idx = $self->istash(__buffers_idx => sub { ++$_[0] });
  my $fname = _get_buffers_path($self, $idx);
  my $bytes = &sereal_encode_with_object($self->{enc},
    {i => $idx, e => $event, a => \@args});
  open my $wev, '>', $fname or die "Couldn't open event file: $!";
  binmode $wev;
  flock($wev, LOCK_EX) or die "Couldn't lock $fname: $!";
  print $wev $bytes;
  close($wev) or die "Couldn't close $fname: $!";
  return $idx;
}


sub _read_event {
  my ($self, $idx) = @_;
  my $fname = _get_buffers_path($self, $idx);
  open my $rev, '<', $fname or die "Couldn't open event file: $!";
  binmode $rev;
  flock($rev, LOCK_SH) or die "Couldn't lock $fname: $!";
  my $bytes = do { local $/; <$rev> };
  close($rev) or die "Couldn't close $fname: $!";
  my $res = &sereal_decode_with_object($self->{dec}, $bytes);
  $self->emit(error => "Overflow trying to get event $idx")
    unless $res->{i} == $idx;
  return $res;
}


sub ikeys {
  my $self = shift;
  $self->_get_vars_path('dummy')
    unless $self->{varsdir};    # initializes $self->{varsdir}
  return $self->{varsdir}->list->map('basename')->to_array;
}


sub istash {
  my ($self, $key, @set_list) = @_;
  my (@val_list, $cb, $has_to_read, $has_to_write);
  $cb           = $set_list[0] if ref $set_list[0] eq 'CODE';
  $has_to_write = 1            if @set_list;
  undef @set_list if $cb;
  $has_to_read = !@set_list;

  unless (exists $self->{catched_vars}->{$key}) {
    my $file = $self->_get_vars_path($key);
    open(my $sf, '>', $self->{vars_semaphore})
      or die "Couldn't open $self->{vars_semaphore} for write: $!";
    flock($sf, LOCK_EX) or die "Couldn't lock $self->{vars_semaphore}: $!";
    unless (-f $file) {
      open my $tch, '>', $file or die "Couldn't touch $file: $!";
      close($tch) or die "Couldn't close $file: $!";
    }
    close($sf) or die "Couldn't close $self->{vars_semaphore}: $!";
    $self->{catched_vars}->{$key} = $file;
  }
  my $fname = $self->{catched_vars}->{$key};            # path to file
  my $lock_flags = $has_to_write ? LOCK_EX : LOCK_SH;
  my $old_length;
  open my $fh, '+<', $fname or die "Couldn't open $fname: $!";
  binmode $fh;
  flock($fh, $lock_flags) or die "Couldn't lock $fname: $!";
  if ($has_to_read) {
    my $slurped_file = do { local $/; <$fh> };
    if ($old_length = length $slurped_file) {
      my ($type, $val) = unpack('a1a*', $slurped_file);
      if ($type eq '=') {
        @val_list = ($val);
      }
      elsif ($type eq 'U') {
        @val_list = decode('UTF-8', $val);
      }
      elsif ($type eq ':') {
        @val_list = @{&sereal_decode_with_object($self->{dec}, $val)};
      }
      else {
        die "Unreconized file content: $type$val";
      }
    }    # else keeps @val_list as an empty array
  }
  @set_list = $cb->(@val_list) if $cb;
  if ($has_to_write) {
    my $to_print;
    if (@set_list == 1 && defined $set_list[0]) {
      my $val = $set_list[0];
      my ($type, $enc_val);
      if (utf8::is_utf8($val)) { $type = 'U'; $enc_val = encode 'UTF-8', $val }
      else                     { $type = '='; $enc_val = $val }
      $to_print = pack 'a1a*', $type, $enc_val;
    }
    elsif (@set_list >= 1) {
      $to_print = pack 'a1a*', ':',
        &sereal_encode_with_object($self->{enc}, \@set_list);
    }
    else {    # set_list is an empty array
      $to_print = '';
    }

    seek $fh, 0, 0;
    print $fh ($to_print);
    my $new_length = length($to_print);
    truncate $fh, $new_length
      if !defined $old_length || $old_length > $new_length;
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
  if ($event =~ /^__(\d+)_\d+$/) {    # unique send
    @ports = ($1);
  }
  else {
    @ports = split /:/, ($self->istash('__ports') // '');
  }
  for my $p (@ports) {
    if ($p == $self->{server_port}) {    # no need to send to itself

      # CAVEAT $self->{events} hash is not docummented in Mojo::EE
      $self->emit($event, @args) if $self->{events}{$event};
      next;
    }
    $idx //= $self->_write_event($event => @args);
    my $id;
    $id = Mojo::IOLoop->client(
      {address => '127.0.0.1', port => $p} => sub {
        my ($loop, $err, $stream) = @_;
        if ($stream) {
          $stream->on(
            error => sub {
              my ($stream, $err) = @_;
              $self->_delete_port($p);
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
            }
          );
          $stream->write($idx => sub { shift->close });
        }
        else {
          $self->_delete_port($p);
          $loop->remove($id);
        }
      }
    );
  }
  $self->{sender_counter}++;
}


sub _init {
  my ($self) = @_;
  $self->{enc} = Sereal::Encoder->new;
  $self->{dec} = Sereal::Decoder->new;

  # define broker msg server
  my $id = Mojo::IOLoop->server(
    {address => '127.0.0.1'} => sub {
      my ($loop, $stream, $id) = @_;
      $stream->on(
        read => sub {
          my ($stream, $bytes) = @_;
          return unless $bytes && $bytes =~ /^(\d+)$/;
          my $res   = $self->_read_event($1);
          my $event = $res->{e};
          my @args  = @{$res->{a}};

          # CAVEAT $self->{events} hash is not docummented in Mojo::EE
          $self->emit($event, @args) if $self->{events}{$event};
          $self->{receiver_counter}++;
        }
      );
    }
  );

  $self->{server_port} = Mojo::IOLoop->acceptor($id)->port;
  $self->istash(
    __ports => sub {
      my %ports = map { $_ => undef } split /:/, (shift // '');
      undef $ports{$self->{server_port}};
      return join ':', keys %ports;
    }
  );
  return $self;
}


sub _delete_port {
  my ($self, $p) = @_;
  $self->istash(
    __ports => sub {
      my %ports = map { $_ => undef } split /:/, (shift // '');
      delete $ports{$p};
      return join ':', keys %ports;
    }
  );
}


sub DESTROY {
  my $self = shift;
  $self->_delete_port($self->{server_port});
}
1;
__END__

=encoding utf-8

=head1 NAME

Mojo::Iutils - Inter Process Communications Utilities without dependences

=head1 SYNOPSIS

	# hit counter, works with daemon, prefork & hypnotoad servers

	use Mojolicious::Lite;
	use Mojo::Iutils;

	helper iutils => sub {state $iutils = Mojo::Iutils->new};

	get '/' => sub {
		my $c = shift;

		# Increment persistent counter "mycounter" with a simple callback.
		# Locking / Unlocking is handled under the hood
		my $cnt = $c->iutils->istash(mycounter => sub {++$_[0]});
		$c->render(text => "Hello, this page was hit $cnt times (and I'm process $$ talking)");
	};

	app->start

	# emit interprocess events (ievent method), works with daemon, prefork & hypnotoad
	# (modified from chat.pl Mojolicious example)

	use Mojolicious::Lite;
	use Mojo::Iutils;
	
	helper events => sub { state $events = Mojo::Iutils->new };
	
	get '/' => 'chat';
	
	websocket '/channel' => sub {
	my $c = shift;

	$c->inactivity_timeout(3600);
	
	# Forward messages from the browser
	$c->on(message => sub { shift->events->iemit(mojochat => shift) });
	
	# Forward messages to the browser
	my $cb = $c->events->on(mojochat => sub { $c->send(pop) });
	$c->on(finish => sub { shift->events->unsubscribe(mojochat => $cb) });
	};
	
	# Minimal multiple-process WebSocket chat application for browser testing

	app->start;
	__DATA__
	
	@@ chat.html.ep
	<form onsubmit="sendChat(this.children[0]); return false"><input></form>
	<div id="log"></div>
	<script>
	var ws  = new WebSocket('<%= url_for('channel')->to_abs %>');
	ws.onmessage = function (e) {
		document.getElementById('log').innerHTML += '<p>' + e.data + '</p>';
	};
	function sendChat(input) { ws.send(input.value); input.value = '' }
	</script>

=head1 DESCRIPTION

Mojo::Iutils provides Persistence and Inter Process Events, without any external dependences beyond
L<Mojolicious> and L<Sereal> Perl Modules.

Its main intents are 1) to be used for microservices (because does not require external services, 
like a database or a pubsub external service, so lowers other dependences), and 2) being very portable, running at least in
main (*)nix distributions, OSX, and Windows (Strawberry perl for cmd users, default perl installation for Cygwin and WSL users)

=head1 EVENTS

L<Mojo::Iutils> inherits all events from L<Mojo::EventEmitter>.


=head1 ATTRIBUTES

L<Mojo::Iutils> implements the following attributes:


=head1 LICENSE

Copyright (C) Daniel Mantovani.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Daniel Mantovani E<lt>dmanto@cpan.orgE<gt>

=cut

