#!perl
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::Util qw/getopt extract_usage/;
use DBI;

my $optsok = getopt
  'f|file=s' => \my $file,
  'm|mode=s' => \my $mode,
  'p|port=i' => \my $port;

die extract_usage unless $file && $mode;

my $dbh = DBI->connect("dbi:SQLite:dbname=$file", "", "");

$dbh->do(
  "CREATE TABLE IF NOT EXISTS int_globals (key TEXT NOT NULL PRIMARY KEY, value INTEGER);"
);

$dbh->do(
  "INSERT INTO int_globals(key,value) SELECT ?,?
     WHERE NOT EXISTS(SELECT 1 FROM int_globals WHERE key=?);", undef, 'port',
  0, 'port'
);

my $cant
  = $dbh->do("UPDATE int_globals set value = -1 where key = ? and value = ?;",
  undef, 'port', 0);

say "Updated: $cant";
$dbh->disconnect;
exit(0);

sub lea {
  my $s = $dbh->prepare('select * from int_globals;');
  $s->execute;
  while (my @rows = $s->fetchrow_array) {
    say join ', ', @rows;
  }
}

=encoding utf8

=head1 SYNOPSIS

    Usage: perl minibroker.pl -d <sqlite db file> -m <mode> [-p <force-port>]

=cut
