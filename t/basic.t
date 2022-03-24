#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use JavaScript::QuickJS;

my $result = JavaScript::QuickJS::run( q<
    [
        true,
        false,
        0,
        -1,
        999,
        99.9999,
        [ "abc", "ünicøde" ],
        { foo: "bar", baz: undefined, undefined: null },
    ]
> );

is_deeply(
    $result,
    [
        !!1,
        !!0,
        0,
        -1,
        999,
        99.9999,
        [ "abc", "ünicøde" ],
        { foo => "bar", baz => undef, undefined => undef },
    ],
    'expected output',
) or diag explain $result;

done_testing;

1;
