#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Fatal;

use JavaScript::QuickJS;

my $js = JavaScript::QuickJS->new();

{
    my $function = $js->eval('() => 42');
    is($function->call(), 42, 'function call accepts an omitted receiver and no arguments');
    is($function->call(undef), 42, 'function call accepts zero arguments');
    is($function->(), 42, 'overloaded function call accepts zero arguments');
}

can_ok('JavaScript::QuickJS', 'engine_version');
SKIP: {
    skip 'engine_version is not available', 2
        unless JavaScript::QuickJS->can('engine_version');

    is(JavaScript::QuickJS->engine_version(), '0.16.2', 'bundled engine version');
    is($js->engine_version(), '0.16.2', 'engine version through an instance');
}

is(
    $js->eval(q{let s = ''; for (let i = 0; i < 200; i++) s += 'abcdefgh'; s}),
    'abcdefgh' x 200,
    'concatenated strings convert to Perl',
);

for my $number ('123n', '123456789012345678901234567890n') {
    like(
        exception { $js->eval($number) },
        qr/big\s*int/i,
        'unsupported BigInt keeps its conversion error',
    );
}

my $result;
is(
    exception { $result = $js->eval(q{[3, 1, 2].toSorted()}) },
    undef,
    'modern array methods are available',
);
is_deeply($result, [1, 2, 3], 'toSorted result converts to Perl');

is(
    $js->eval(q{
        try {
            Reflect.ownKeys(new Proxy({}, {ownKeys() { return 1; }}));
            false;
        } catch (e) { e instanceof TypeError; }
    }),
    1,
    'Proxy ownKeys must return an object',
);

is(
    $js->eval(q{
        let calls = 0;
        [1, 1].sort(() => { calls++; return 0; });
        calls > 0;
    }),
    1,
    'sort calls the comparator for identical values',
);

is_deeply(
    $js->eval('new Proxy(new Proxy([1, 2], {}), {})'),
    [1, 2],
    'array proxies keep array conversion',
);

is_deeply(
    $js->eval(q{
        new Proxy([1, 2], {
            get(target, key) {
                return key === '0' ? 42 : Reflect.get(target, key);
            }
        })
    }),
    [42, 2],
    'array conversion reads through Proxy traps',
);

for my $specimen (
    ['new Proxy({}, {ownKeys() { return 1; }})', qr/TypeError/],
    ['new Proxy([1], {get() { throw new Error("array getter"); }})', qr/array getter/],
    ['({get value() { throw new Error("object getter"); }, other: 1})', qr/object getter/],
    ['(() => { const p = Proxy.revocable([], {}); p.revoke(); return p.proxy; })()', qr/revoked/i],
) {
    like(
        exception { $js->eval($specimen->[0]) },
        $specimen->[1],
        'conversion exception reaches Perl',
    );
    is($js->eval('40 + 2'), 42, 'runtime is usable after a conversion exception');
}

done_testing;
