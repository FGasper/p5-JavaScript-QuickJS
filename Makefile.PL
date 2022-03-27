#!/usr/bin/env perl

use strict;
use warnings;

use ExtUtils::MakeMaker::CPANfile;

use Config;

use File::Temp;
use File::Which;

open my $rfh, '<', 'quickjs/Makefile' or die "open Makefile: $!";
my $make = do { local $/; <$rfh> };

$make =~ s<^(\s*CFLAGS\s*=\s*)><$1 -fPIC >mg;

my ($fh, $path) = File::Temp::tempfile( CLEANUP => 1 );
syswrite $fh, $make or die "write temp make: $!";
close $fh;

my $make_bin = File::Which::which('gmake') || $Config{'make'};

system $make_bin, '-C', 'quickjs', '-f', $path, 'libquickjs.a' and die;

# quickjs needs these; pre-5.20 perls didn’t include libpthread:
my @libs = qw(-lm -ldl -lpthread);

# RaspiOS needs this:
if (_has_libatomic()) {
    push @libs, '-latomic';
}

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

    LIBS => "@libs",

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

sub _has_libatomic {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    open my $fh, '>', "$dir/test.c";
    syswrite $fh, join(
        "\n",
        'int main() { return 0; }',
    );

    print "Checking whether this system uses libatomic …\n";

    my $ok = !system $Config{'cc'}, "$dir/test.c", '-latomic';

    print "\t… " . ($ok ? 'Looks like it.' : 'Guess not.') . "\n";

    return $ok;
}
