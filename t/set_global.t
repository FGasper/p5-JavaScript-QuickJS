#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Data::Dumper;

use JavaScript::QuickJS;

my $js = JavaScript::QuickJS->new()->set_global(
    add1 => sub { $_[0] + 1 },
);

is( $js->eval("add1(23)"), 24, 'JS calls Perl' );

my @roundtrip = (
    "hello",
    "\xe9",
    "\x{100}",
    "\x{101234}",
    -1,
    -1.234,
    0,
    1.234,
    0xffff_ffff,
    [1, 2, 3],
    [],
    {},
    { foo => 'bar' },
    { "\x{100}" => [] },
);

for my $rtval (@roundtrip) {
    my $key = 'rtval';

    $js->set_global( $key => $rtval );

    my $got = $js->eval($key);

    local $Data::Dumper::Useqq =1;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Indent = 0;
    my $str = Dumper($rtval);

    is_deeply($got, $rtval, "gave & received: $str" );
}

eval { $js->set_global( regexp => qr/abc/ ) };
my $err = $@;

like($err, qr<abc>, 'error mentions what can’t be converted');
like($err, qr<javascript>i, 'error mentions JS');

done_testing;
