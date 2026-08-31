#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::FailWarnings;
use Scalar::Util qw(weaken);

use JavaScript::QuickJS;

{
    my $return;

    my $js = JavaScript::QuickJS->new();

    $js->set_globals(  __return => sub { $return = shift } );

    my $ret = $js->eval('__return( a => a );');

    isa_ok(
        $return,
        'JavaScript::QuickJS::Function',
        'eval() of an arrow function',
    );

    like(
        "$return",
        qr<JavaScript::QuickJS::Function>,
        'stringification',
    );

    undef $return;

}

{
    my $js = JavaScript::QuickJS->new();
    my ($weak_state, $weak_callback);
    {
        my $state = { increment => 1 };
        $weak_state = $state;
        weaken($weak_state);

        my $callback = sub { $_[0] + $state->{increment} };
        $weak_callback = $callback;
        weaken($weak_callback);
        $js->set_globals(add_one => $callback, alias => $callback);
    }
    ok(defined $weak_callback, 'context retains registered callbacks');

    my $function = $js->eval('value => add_one(value)');
    undef $js;
    is($function->(41), 42, 'exported function retains the callback context');
    ok(defined $weak_state, 'callback state remains alive with the context');

    undef $function;
    ok(!defined $weak_callback, 'callbacks are released with the last context owner');
    ok(!defined $weak_state, 'callback state is released with the last context owner');
}

done_testing;
