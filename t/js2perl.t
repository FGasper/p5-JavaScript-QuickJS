#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use JavaScript::QuickJS;

my $js = JavaScript::QuickJS->new();

eval { $js->eval('[BigInt(123)]') };
my $err = $@;
like($err, qr<big\s*int>i, 'BigInt in array');

eval { $js->eval('let foo = { foo: BigInt(123) }; foo') };
$err = $@;
like($err, qr<big\s*int>i, 'BigInt in plain object');

for my $specimen (
    ['({get value() { throw new Error("object getter"); }, other: 1})', qr/object getter/],
    ['new Proxy({}, {ownKeys() { throw new Error("ownKeys failed"); }})', qr/ownKeys failed/],
    ['new Proxy([1], {get() { throw new Error("array length"); }})', qr/array length/],
    ['new Proxy([1], {get(target, key) {
        return key === "length" ? {valueOf() { throw new Error("length conversion"); }} : target[key];
    }})', qr/length conversion/],
    ['[1, {get value() { throw new Error("nested getter"); }}]', qr/nested getter/],
    ['(() => { const p = Proxy.revocable([], {}); p.revoke(); return p.proxy; })()', qr/revoked/i],
    ['({get value() { throw {toString() { throw new Error("stringification"); }}; }})',
        qr/exception could not be converted to a string/],
) {
    eval { $js->eval($specimen->[0]) };
    like($@, $specimen->[1], 'conversion exception reaches Perl');
    is($js->eval('40 + 2'), 42, 'context remains usable after a conversion exception');
}

# A conversion failure must release atoms for properties not yet visited.
my @unexpected_errors;
for (1 .. 100) {
    eval { $js->eval('({first: 123n, unused: 1, alsoUnused: 2})') };
    push @unexpected_errors, $@ unless $@ =~ /big\s*int/i;
}
is_deeply(\@unexpected_errors, [], 'unsupported values keep reporting their conversion error');
undef $js;
pass('context can be destroyed after repeated conversion failures');

done_testing;
