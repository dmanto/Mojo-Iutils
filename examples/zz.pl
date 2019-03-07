use Devel::Cycle;
use Mojo::Iutils;

my $c = Mojo::Iutils->new;
find_weakened_cycle($c);
exit(0);