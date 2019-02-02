[![Build Status](https://travis-ci.org/dmanto/Mojo-Iutils.svg?branch=master)](https://travis-ci.org/dmanto/Mojo-Iutils) [![Build Status](https://img.shields.io/appveyor/ci/dmanto/Mojo-Iutils/master.svg?logo=appveyor)](https://ci.appveyor.com/project/dmanto/Mojo-Iutils/branch/master)
# NAME

Mojo::Iutils - Inter Process Communications Utilities without dependences

# SYNOPSIS

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

# DESCRIPTION

Mojo::Iutils provides Persistence and Inter Process Events, without any external dependences beyond
[Mojolicious](https://metacpan.org/pod/Mojolicious) and [Sereal](https://metacpan.org/pod/Sereal) Perl Modules.

Its main intents are 1) to be used for microservices (because does not require external services, 
like a database or a pubsub external service, so lowers other dependences), and 2) being very portable, running at least in
main (\*)nix distributions, OSX, and Windows (Strawberry perl for cmd users, default perl installation for Cygwin and WSL users)

# EVENTS

[Mojo::Iutils](https://metacpan.org/pod/Mojo::Iutils) inherits all events from [Mojo::EventEmitter](https://metacpan.org/pod/Mojo::EventEmitter).

# ATTRIBUTES

[Mojo::Iutils](https://metacpan.org/pod/Mojo::Iutils) implements the following attributes:

## app\_mode

    my $iutils = Mojo::Iutils->new(app_mode => 'test');

Used to force application mode. This value will be taken to generate the default base\_dir attribute;

## base\_dir

    my $base_dir = $iutils->base_dir;
    $iutils = $iutils->base_dir($app->home('iutilsdir', $app->mode));

Base directory to be used by [Mojo::Iutils](https://metacpan.org/pod/Mojo::Iutils). Must be the same for different applications if they
need to communicate among them.

It should include the mode of the application, otherwise testing will probably interfere with production
files so you will not be able to test an application safelly on a production server.

Defaults for a temporary directory. It also includes the running user name, so to avoid permission problems
on automatic (matrix CI) installations with different users.

## buffer\_size

    my $buffer_size = $iutils->buffer_size;
    my $iutils = Mojo::Iutils->new(buffer_size => 512);
    $iutils = $iutils->buffer_size(1024);

The size of the circular buffer used to store events. Should be big enough to
handle slow attended events, or it will die with an overflow error.

# METHODS

[Mojo::Iutils](https://metacpan.org/pod/Mojo::Iutils) inherits all events from [Mojo::EventEmitter](https://metacpan.org/pod/Mojo::EventEmitter), and implements the following new ones:

## iemit

    $iutils = $iutils->iemit('foo');
    $iutils = $iutils->iemit('foo', 123);

Emit event to all connected processes. Similar to calling [Mojo::EventEmitter](https://metacpan.org/pod/Mojo::EventEmitter)'s emit method
in all processes, but doesn't emit an error event if event is not registered.

## istash

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
    $iutils->istash)foo => sub {my @z = @_; push @z, $x; @z}; # pushes $x to array in foo

The three operations are thread & fork safe. Get data gets a shared lock, while
set and modify get an exclusive lock.

## new

    my $iutils = Mojo::Iutils->new;

Constructs a new [Mojo::Iutils](https://metacpan.org/pod/Mojo::Iutils) object.

## unique

    my $u = $iutils->unique;
    $iutils->on($u => sub {...}); # register event with unique name in same object

Then in other part of the code, in any process that knows $u value

    $other_iutils->emit($u => @args);

strings generated with this method are not broadcasted, but sent only to the target process

# LICENSE

Copyright (C) Daniel Mantovani.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Daniel Mantovani <dmanto@cpan.org>
