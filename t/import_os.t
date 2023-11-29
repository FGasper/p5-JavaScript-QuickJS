#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use JavaScript::QuickJS;

my $js = JavaScript::QuickJS->new()->os();

$js->eval_module( q<import * as what from "os";> );

pass;

done_testing;
