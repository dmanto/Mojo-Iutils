requires 'perl', '5.008001';
requires 'Mojolicious', '8.11';
requires 'Sereal', '4.005';

on 'test' => sub {
    requires 'Test2::V0';
    requires 'Test2::IPC';
    requires 'Test::More', '0.98';
};

