#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Fatal;

use JavaScript::QuickJS;

my $js = JavaScript::QuickJS->new();
$js->eval('Promise.reject(new Error("unhandled rejection")); undefined');
like(
    exception { $js->await() },
    qr/unhandled rejection/,
    'await throws an unhandled rejection without exiting Perl',
);
is(exception { $js->await() }, undef, 'reported rejections are cleared');

$js->eval(q{
    Promise.reject(new Error('handled rejection')).catch(() => {});
    undefined;
});
is(exception { $js->await() }, undef, 'handled rejection is not reported');

$js->eval(q{
    const p = Promise.reject('handled later');
    Promise.resolve().then(() => p.catch(() => {}));
    undefined;
});
is(exception { $js->await() }, undef, 'microtasks can attach a rejection handler');

$js->eval(q{
    Promise.reject('first rejection');
    Promise.reject('second rejection');
    undefined;
});
like(exception { $js->await() }, qr/first rejection/, 'first remaining rejection is reported');
is(exception { $js->await() }, undef, 'multiple reported rejections are cleared');

$js->eval(q{
    Promise.reject({toString() { throw new Error('stringification failed'); }});
    undefined;
});
like(
    exception { $js->await() },
    qr/exception could not be converted to a string/,
    'unprintable rejection does not corrupt the exception state',
);
is(exception { $js->await() }, undef, 'unprintable rejection is cleared');

$js->set_globals(fail_in_perl => sub { die "Perl callback failed\n" });
$js->eval('Promise.resolve().then(fail_in_perl); undefined');
like(exception { $js->await() }, qr/Perl callback failed/, 'async Perl callback error');

$js->os()->eval('os.setTimeout(() => { throw new Error("timer failed"); }, 0); undefined');
like(exception { $js->await() }, qr/timer failed/, 'timer exceptions reach Perl');
is($js->eval('6 * 7'), 42, 'runtime remains usable after asynchronous errors');

{
    my $other = JavaScript::QuickJS->new();
    $other->eval('Promise.reject("discarded with runtime"); undefined');
}
pass('runtime with an unhandled rejection can be destroyed');

{
    my $retained = JavaScript::QuickJS->new()->eval(q{
        () => { Promise.reject('late rejection'); return 42; }
    });
    is($retained->(), 42, 'exported function retains the context and rejection tracker');
}

done_testing;
