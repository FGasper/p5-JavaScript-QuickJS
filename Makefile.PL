#!/usr/bin/env perl

use strict;
use warnings;

use ExtUtils::MakeMaker::CPANfile;

use Config;

use File::Temp;

open my $rfh, '<', 'quickjs/Makefile' or die "open Makefile: $!";
my $make = do { local $/; <$rfh> };

$make =~ s<^(\s*CFLAGS\s*=\s*)><$1 -fPIC >mg;

my ($fh, $path) = File::Temp::tempfile( CLEANUP => 1 );
syswrite $fh, $make or die "write temp make: $!";
close $fh;

system $Config{'make'}, '-C', 'quickjs', '-f', $path, 'libquickjs.a' and die;

WriteMakefile(
    NAME              => 'JavaScript::QuickJS',
    VERSION_FROM      => 'lib/JavaScript/QuickJS.pm', # finds $VERSION
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/JavaScript/QuickJS.pm', # retrieve abstract from module
       AUTHOR         => [
            'Felipe Gasper (FELIPE)',
        ],
      ) : ()
    ),
    INC               => '-Wall --std=c99 -I.',
    LICENSE           => "perl_5",

    # quickjs needs these:
    LIBS => '-lm -ldl -lpthread',

    OBJECT => [
        '$(BASEEXT)$(OBJ_EXT)',
        'quickjs/libquickjs.a',
    ],

    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url => 'git://github.com/FGasper/p5-JavaScript-QuickJS.git',
                web => 'https://github.com/FGasper/p5-JavaScript-QuickJS',
            },
            bugtracker => {
                web => 'https://github.com/FGasper/p5-JavaScript-QuickJS/issues',
            },
        },
    },
);
