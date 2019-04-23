package Mojo::Iutils;
use Mojo::Base 'Mojo::EventEmitter';
use Carp 'croak';
use Scalar::Util 'weaken';
use POSIX ();
use Fcntl ':flock';
use Time::HiRes qw/sleep/;
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

our $VERSION = '0.07';
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
  $self->{enc} //= Sereal::Encoder->new;
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
  $self->{dec} //= Sereal::Decoder->new;
  my $res = &sereal_decode_with_object($self->{dec}, $bytes);
  $self->emit(error => "Overflow trying to get event $idx")
    unless $res->{i} == $idx;
  return $res;
}


sub _ikeys {
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
        $self->{dec} //= Sereal::Decoder->new;
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
      $self->{enc} //= Sereal::Encoder->new;
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

sub unique {
  my $self = shift;
  return '__' . $self->{_lport} . '_' . ++$self->{unique_count};
}

sub iemit {
  my ($self, $event) = (shift, shift);
  my @args      = @_;
  my $unique_id = '';

  my ($local_emit, $remote_emit);
  if ($event =~ /^__(\d+)_\d+$/) {    # unique send
    my $u = $1;
    $local_emit  = $self->{_client} eq $u;
    $remote_emit = !$local_emit;
    $unique_id   = $u . ':';
  }
  else {
    $local_emit = $remote_emit = 1;
  }

  # CAVEAT $self->{events} hash is not docummented in Mojo::EE
  $self->emit($event, @args) if $local_emit && $self->{events}{$event};

  $self->{_client}->write(
    $unique_id . $self->_write_event($event => @args) . "\n" => sub {
      $self->{sender_counter}++;
    }
  ) if $remote_emit;

  return $self;
}


sub _init {
  my ($self) = @_;
  my $broker_port = -2;
  while ($broker_port < 0) {
    $broker_port = $self->istash(
      __broker => sub {
        my $p = shift;
        if    (!defined $p) { $p = -1 }
        elsif ($p == -1)    { $p = -2 }
        return $p;
      }
    );
    $self->_broker_server
      if $broker_port == -1;    # only one process will get this
    $self->_broker_client($broker_port)
      if $broker_port > 0;      # other processes eventually will get this
    sleep .25;                  # be nice to other processes
  }
  return $self;
}

sub _broker_server {
  my ($self) = @_;
  die "Can't fork: $!" unless defined(my $pid = fork);
  if (!$pid) {
    POSIX::setsid() or die "Can't start a new session: $!";

    # define broker msg server
    die "Can't fork: $!" unless defined(my $pid2 = fork);
    POSIX::_exit(0) if $pid2;
    my $id = Mojo::IOLoop->server(
      {address => '127.0.0.1'} => sub {
        my ($loop, $stream, $id) = @_;
        $stream->timeout(0);
        my $rport = $stream->handle->peerport;
        $self->{_conns}{$rport} = $stream;
        my $pndg = '';
        $stream->on(
          read => sub {
            my ($stream, $bytes) = @_;
            return unless defined $bytes;
            my @msgs = split /\n/, $pndg . $bytes, -1;    # keep last separator
            $pndg = pop @msgs // '';
            for my $msg (@msgs) {
              next unless $msg && $msg =~ /(?:(\d+):)?(\d+)$/;
              my ($unique, $idx) = ($1, $2);
              if (defined $unique) {
                $self->{_conns}{$unique}->write("$idx\n")
                  if $self->{_conns}{$unique};
              }
              else {
                for my $p (keys %{$self->{_conns}}) {
                  $self->{_conns}{$p}->write("$idx\n")
                    unless $p eq $rport;                  # skip the emitter
                }
              }
            }
          }
        );
        $stream->on(
          close => sub {
            delete $self->{_conns}{$rport};
            my $left = join ':', keys %{$self->{_conns}};

            say STDERR "$$: recibio close para puerto $rport, quedan $left";
            $loop->stop
              unless keys %{$self->{_conns}};   # keep running if has connectons
          }
        );
        $stream->on(
          error => sub {
            delete $self->{_conns}{$rport};
            $loop->stop
              unless keys %{$self->{_conns}};   # keep running if has connectons
          }
        );
      }
    );

    $self->{server_port} = Mojo::IOLoop->acceptor($id)->port;
    $self->istash(__broker => $self->{server_port});
    Mojo::IOLoop->start;
    $self->istash(__broker => undef);           #
    POSIX::_exit(0);
  }
  $self->{_isparent} = 1;
  return $self;                                 # parent
}

sub _broker_client {
  my ($self, $port) = @_;
  my $tid = Mojo::IOLoop->timer(
    10 => sub {
      my $loop = shift;
      $self->istash(__broker => undef);         # too bad, server not working
      die "Mojo::Iutils client can't connect to broker";
    }
  );
  Mojo::IOLoop->client(
    {address => '127.0.0.1', port => $port} => sub {
      my ($loop, $err, $stream) = @_;
      if ($stream) {
        my $pndg = '';                          # pending data
        $loop->remove($tid);                    # no timeout
        $stream->timeout(0);                    # permanent
        $stream->on(
          read => sub {
            my ($stream, $bytes) = @_;
            return unless defined $bytes;
            my @idxs = split /\n/, $pndg . $bytes, -1;    # keep last separator
            $pndg = pop @idxs // '';
            for my $idx (@idxs) {

              # say STDERR "Cliente recibio idx $idx";
              my $res   = $self->_read_event($idx);
              my $event = $res->{e};
              my @args  = @{$res->{a}};

              # CAVEAT $self->{events} hash is not docummented in Mojo::EE
              $self->emit($event, @args) if $self->{events}{$event};
              $self->{receiver_counter}++;

              # say STDERR "Recibio evento $event";
            }
          }
        );
        $stream->on(
          close => sub {
            delete $self->{_client};
          }
        );
        my $aux_stream = $stream;
        $self->{_client} = $aux_stream;                 # for interprocess emits
        $self->{_lport}  = $stream->handle->sockport;   # as a client id
        weaken($self->{_client});
      }
    }
  );

  # my $z;
  while (!$self->{_client}) {
    Mojo::IOLoop->timer(0.05 => sub { shift->stop_gracefully });
    Mojo::IOLoop->start;

    # say STDERR "Reintento numero " . ++$z;
  }

  # say STDERR "Cliente se conecto con puerto " . $self->{_lport};
  return $self;
}

sub DESTROY {
  my $self = shift;
  say "Llamo a DESTROY en server" if defined $self->{server_port};
  say "Llamo a DESTROY en client" if defined $self->{_client};
  $self->istash(__broker => undef) if defined $self->{server_port};
  $self->{_client}->close if $self->{_client};
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

=head2 app_mode

  my $iutils = Mojo::Iutils->new(app_mode => 'test');

Used to force application mode. This value will be taken to generate the default base_dir attribute;

=head2 base_dir

  my $base_dir = $iutils->base_dir;
  $iutils = $iutils->base_dir($app->home('iutilsdir', $app->mode));

Base directory to be used by L<Mojo::Iutils>. Must be the same for different applications if they
need to communicate among them.

It should include the mode of the application, otherwise testing will probably interfere with production
files so you will not be able to test an application safelly on a production server.

Defaults for a temporary directory. It also includes the running user name, to avoid permission problems
on automatic (matrix) tester installations with different users (i.e. with and without sudo cpanm installs).

=head2 buffer_size

  my $buffer_size = $iutils->buffer_size;
  my $iutils = Mojo::Iutils->new(buffer_size => 512);
  $iutils = $iutils->buffer_size(1024);

The size of the circular buffer used to store events. Should be big enough to
handle slow attended events, or it will die with an overflow error.

=head1 METHODS

L<Mojo::Iutils> inherits all events from L<Mojo::EventEmitter>, and implements the following new ones:

=head2 iemit

  $iutils = $iutils->iemit('foo');
  $iutils = $iutils->iemit('foo', 123);

Emit event to all connected processes. Similar to calling L<Mojo::EventEmitter>'s emit method
in all processes, but doesn't emit an error event if event is not registered.

=head2 istash

  $iutils->istash(foo => 123);
  my $foo = $iutils->istash('foo'); # 123
  my %bar = $iutils->istash(bar => (baz => 23)); # %bar = (baz => 23)

It supports three modes of operation. Just get recorded data:

  my $scalar = $iutils->istash('foo');
  my @array = $iutils->istash('bar');
  my %hash = $iutils->istash('baz');

Set data (returning same data):

  my $scalar = $iutils->istash(foo => 'some scalar');
  my @array = $iutils->istash(bar => qw/some array/;
  my %hash = $iutils->istash(baz => (some => 'hash'));

Modify data with code

  $iutils->istash(foo => undef); # clears var foo
  $iutils->istash(foo => sub {my @z = @_; push @z, $x; @z}); # pushes $x to array in foo

The three operations are thread & fork safe. Get data gets a shared lock, while
set and modify get an exclusive lock.

=head2 new

  my $iutils = Mojo::Iutils->new;

Constructs a new L<Mojo::Iutils> object.

=head2 unique

  my $u = $iutils->unique;
  $iutils->on($u => sub {...}); # register event with unique name in same object

Then in other part of the code, in any process that knows $u value

  $other_iutils->emit($u => @args);

strings generated with this method are not broadcasted, but sent only to the target process

=head1 LICENSE

Copyright (C) Daniel Mantovani.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Daniel Mantovani E<lt>dmanto@cpan.orgE<gt>

=cut

