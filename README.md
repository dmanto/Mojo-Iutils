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

# LICENSE

Copyright (C) Daniel Mantovani.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Daniel Mantovani <dmanto@cpan.org>
