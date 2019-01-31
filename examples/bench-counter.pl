# hit counter, works with daemon, prefork & hypnotoad servers

use Mojolicious::Lite;
use Mojo::Iutils;
use Mojo::SQLite;
use Mojo::Pg;
use Mojo::Redis;

helper iutils => sub { state $iutils = Mojo::Iutils->new };
helper sqlite => sub { state $sqlite = Mojo::SQLite->new('file:test.db') };
helper pg     => sub { state $pg     = Mojo::Pg->new('postgresql:///test') };
helper redis  => sub { state $redis  = Mojo::Redis->new };

app->sqlite->migrations->from_string("
-- 1 up
create table glb (k text primary key, v integer);
insert into glb(k, v) values ('my_counter', 0);
-- 1 down
drop table glb;
")->migrate;
app->pg->migrations->from_string("
-- 1 up
create table glb (k text primary key, v integer);
insert into glb(k, v) values ('my_counter', 0);
-- 1 down
drop table glb;
")->migrate;

get '/sqlite' => sub {
  my $c = shift;
  my $db = $c->sqlite->db;
  $db->query("update glb set v=v+1 where k='my_counter'");
  my $cnt = $db->query("select v from glb where k='my_counter'")->array->[0];
  $c->render(text => "Counter: $cnt");
};
get '/pg' => sub {
  my $c  = shift;
  my $db = $c->pg->db;
  $db->query("update glb set v=v+1 where k='my_counter'");
  my $cnt = $db->query("select v from glb where k='my_counter'")->hash->{v};
  $c->render(text => "Counter: $cnt");
};
get '/istash' => sub {
  my $c = shift;
  my $cnt = $c->iutils->istash(mycounter => sub { ++$_[0] });
  $c->render(text => "Counter: $cnt");
};
get '/redis' => sub {
  my $c   = shift;
  my $cnt = $c->redis->db->incr('mycounter');
  $c->render(text => "Counter: $cnt");
};

app->start
