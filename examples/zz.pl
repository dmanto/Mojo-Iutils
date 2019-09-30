package Mojo::Iutils;
use Mojo::Base 'Mojo::EventEmitter';
has 'lid';
sub pmethod {
    my $self = shift;
    say "Soy el metodo en Mojo::Iutils, lid = ". $self->lid;
}

package Mojo::Iutils::Client;
use Mojo::Base 'Mojo::Iutils';
sub cmethod {
    my $self = shift;
    say "Soy el metodo en Mojo::Iutils::Client, lid = ". $self->lid;
}

package Mojo::Iutils::Server;
use Mojo::Base 'Mojo::Iutils';
sub cmethod {
    my $self = shift;
    say "Soy el metodo en Mojo::Iutils::Server, lid = ". $self->lid;
}

my $s1 = Mojo::Iutils::Server->new;
my $c1 = Mojo::Iutils::Client->new;

$c1->on(ev1 => sub {
    my ($ev, @args) = @_;
    say "Se disparo el evento $ev en c1";
} );

$s1->emit(ev1 => 'hola');

say "Fin";