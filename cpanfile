requires 'perl', '5.12';
requires 'Mojolicious', '8.11';
requires 'Sereal', '4.005';

on 'test' => sub {
    requires 'Test2::V0';
};
