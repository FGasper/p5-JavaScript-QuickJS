#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use JavaScript::QuickJS;

my $js = JavaScript::QuickJS->new()->set_global(
    add1 => sub { $_[0] + 1 },
);

is( $js->eval("add1(23)"), 24, 'JS calls Perl' );

done_testing;
