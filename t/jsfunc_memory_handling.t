#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::FailWarnings;

use JavaScript::QuickJS;

{
    my $return;

    my $js = JavaScript::QuickJS->new();

    $js->set_globals(  __return => sub { $return = shift; } );

    isa_ok(
        $js->eval('__return( a => a )'),
        'JavaScript::QuickJS::Function',
        'eval() of an arrow function',
    );
}

done_testing;
