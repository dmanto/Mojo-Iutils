use Mojolicious::Lite;
use lib './lib';
use Mojo::Iutils;
 
helper events => sub { state $events = Mojo::Iutils->new };
 
get '/' => sub {
    my $c = shift;
    sleep 10;
    return $c->render('chat');
};
 
websocket '/channel' => sub {
  my $c = shift;
  say STDERR "Pidieron un websocket en $$";
  $c->inactivity_timeout(3600);
 
  # Forward messages from the browser
  $c->on(message => sub { shift->events->iemit(mojochat => shift) });
 
  # Forward messages to the browser
  my $cb = $c->events->on(mojochat => sub { $c->send(pop) });
  $c->on(finish => sub { shift->events->unsubscribe(mojochat => $cb) });
};
 
# Minimal multiple-process WebSocket chat application for browser testing
app->hook(before_server_start => sub {
  my ($server, $app) = @_;
  $server->max_clients(1);
});
app->start;
__DATA__
 
@@ chat.html.ep
<p> From process <%= $$ %> local port <%= events->server_port %></p>
<form onsubmit="sendChat(this.children[0]); return false"><input></form>
<div id="log"></div>
<script>
  var ws  = new WebSocket('<%= url_for('channel')->to_abs %>');
  ws.onmessage = function (e) {
    document.getElementById('log').innerHTML += '<p>' + e.data + '</p>';
  };
  function sendChat(input) { ws.send(input.value); input.value = '' }
</script>