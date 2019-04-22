# hit counter, works with daemon, prefork & hypnotoad servers

use Mojolicious::Lite;
use Mojo::Iutils;

helper iutils => sub { state $iutils = Mojo::Iutils->new };

get '/' => sub {
  my $c = shift;
  my $cnt = $c->iutils->istash(mycounter => sub { ++$_[0] });
  $c->render(
    text => "Hello, this page was hit $cnt times (and I'm process $$ talking)");
};

app->start
