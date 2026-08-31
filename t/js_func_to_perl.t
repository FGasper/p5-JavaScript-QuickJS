#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use JavaScript::QuickJS;

my $js = JavaScript::QuickJS->new();

my $cb = $js->helpers->eval("(val) => val + 1");

isa_ok($cb, 'JavaScript::QuickJS::Function', 'JS callback');

is($cb->length(), 1, 'length() gives arity');
is($cb->name(), q<>, 'name()');

is(
    $cb->(2),
    3,
    'JS function called from Perl',
);

undef $cb;

pass 'Still alive (callback reaped)';

undef $js;

pass 'Still alive (JS reaped)';

#----------------------------------------------------------------------

$js = JavaScript::QuickJS->new();

my $cb2 = $js->eval("let f = function myFunc(foo, bar) {}; f");

isa_ok($cb2, 'JavaScript::QuickJS::Function', 'JS callback (declaration)');

is($cb2->length(), 2, 'length() gives arity');
is($cb2->name(), q<myFunc>, 'name()');

my $no_args = $js->eval('(function () { return arguments.length; })');
is($no_args->call(), 0, 'call() accepts an omitted receiver and no arguments');
is($no_args->call(undef), 0, 'call(undef) passes no arguments');
is($no_args->(), 0, 'overloaded invocation passes no arguments');

my $receiver = $js->eval('(function () { return this.answer; })');
is($receiver->call({ answer => 42 }), 42, 'explicit receiver with no arguments');

done_testing();
