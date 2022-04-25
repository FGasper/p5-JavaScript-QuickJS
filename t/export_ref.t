#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::FailWarnings;
use Data::Dumper;
use Config;

use Types::Serialiser;

use JavaScript::QuickJS;

my $ret;

{
    my $js = JavaScript::QuickJS->new()->set_globals(
        __return => sub { $ret = shift },
    );

    $js->eval('__return( function add1(a) { return 1 + a } )');
}

is(
    $ret->(1),
    2,
    'add1 called without QuickJS instance',
);

undef $ret;

done_testing;
