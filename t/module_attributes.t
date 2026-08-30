#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Fatal;
use File::Temp;
use File::Slurper;

use JavaScript::QuickJS;

my $dir = File::Temp::tempdir(CLEANUP => 1);
File::Slurper::write_binary("$dir/data.json", '{"answer":42}');

my $js = JavaScript::QuickJS->new()->set_module_base($dir);
my $result;
$js->set_globals(capture => sub { $result = shift; return; });

my $promise = $js->eval_module(q{
    import data from './data.json' with {type: 'json'};
    capture(data);
});
isa_ok($promise, 'JavaScript::QuickJS::Promise');
$js->await();
is_deeply($result, {answer => 42}, 'static JSON import honors the module base');

$result = undef;
$js->eval(q{
    import('./data.json', {with: {type: 'json'}}).then(module => capture(module.default));
    undefined;
});
$js->await();
is_deeply($result, {answer => 42}, 'dynamic JSON import forwards attributes');

like(
    exception { $js->eval_module(q{import data from './data.json' with {type: 'invalid'};}) },
    qr/(?:TypeError|unsupported)/i,
    'unsupported import attributes are rejected',
);

done_testing;
