use Devel::Cycle;
use Mojo::Iutils;
####


{ sort: sort };
my $c = Mojo::Iutils->new;
find_weakened_cycle($c);
exit(0);
