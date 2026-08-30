#!/usr/bin/env perl

use strict;
use warnings;

use ExtUtils::MakeMaker::CPANfile;
use ExtUtils::CBuilder;
use Config;
use Cwd;
use File::Spec;
use File::Temp;

my @qjs_sources = qw(dtoa libregexp libunicode quickjs quickjs-libc);
my @qjs_objects = map { "qjs$_\$(OBJ_EXT)" } @qjs_sources;
my @qjs_headers = glob 'quickjs/*.h';
my $cflags = '-std=c11';
$cflags .= ' -funsigned-char' unless $^O eq 'solaris';

my @libs = ($^O eq 'MSWin32') ? () : qw(-lm -lpthread);
push @libs, '-ldl' if $^O =~ /^(?:linux|darwin|cygwin|solaris)$/;
push @libs, '-lrt' if _need_librt();
push @libs, '-latomic' if _should_link_libatomic();

WriteMakefile(
    NAME => 'JavaScript::QuickJS',
    VERSION_FROM => 'lib/JavaScript/QuickJS.pm',
    ABSTRACT_FROM => 'lib/JavaScript/QuickJS.pm',
    AUTHOR => ['Felipe Gasper (FELIPE)'],
    LICENSE => 'perl_5',
    INC => '-I.',
    CCFLAGS => "$Config{ccflags} -Wall $cflags",
    DEFINE => '-D_GNU_SOURCE -DQUICKJS_NG_BUILD -DQJS_BUILD_LIBC',
    PMLIBDIRS => ['lib'],
    LIBS => "@libs",
    OBJECT => join(' ', '$(BASEEXT)$(OBJ_EXT)', @qjs_objects),
    depend => {
        'QuickJS$(OBJ_EXT)' => join(' ', @qjs_headers, glob 'easyxs/*.h'),
    },
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

sub _compile_and_link {
    my ($source, $libs) = @_;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'test.c');

    open my $fh, '>', $path or die "open($path): $!";
    print {$fh} $source or die "write($path): $!";
    close $fh or die "close($path): $!";

    my $builder = ExtUtils::CBuilder->new(quiet => 1);
    my $ok = eval {
        my $object = $builder->compile(
            source => $path,
            extra_compiler_flags => $cflags . ' -I"' . Cwd::getcwd() . '"',
        );
        $builder->link_executable(
            objects => $object,
            extra_linker_flags => $libs || '',
        );
        1;
    };

    return !!$ok;
}

sub _need_librt {
    return 0 unless $^O eq 'linux';

    return !_compile_and_link(<<'C');
#include <stdlib.h>
#if defined(__GLIBC__) && (__GLIBC__ < 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ < 17))
#error This system needs librt
#endif
int main(void) { return 0; }
C
}

sub _should_link_libatomic {
    my $env_key = 'JS_QUICKJS_LINK_LIBATOMIC';
    if (defined $ENV{$env_key}) {
        die "Set $env_key to 1 or a falsy value.\n"
            if $ENV{$env_key} && $ENV{$env_key} ne '1';
        return !!$ENV{$env_key};
    }

    my $probe = <<'C';
#include <stdint.h>
#include "quickjs/quickjs-c-atomics.h"
static volatile _Atomic uint64_t value;
int main(void) {
    atomic_fetch_add(&value, 1);
    return (int)atomic_load(&value);
}
C

    print "Checking whether QuickJS needs libatomic ...\n";
    return 0 if _compile_and_link($probe);
    return 1 if _compile_and_link($probe, '-latomic');
    die "QuickJS requires a C11 compiler with atomics support, and libatomic where needed.\n";
}

package MY;

sub postamble {
    # Distinct root-level names also work on case-insensitive filesystems,
    # where quickjs.o and the XS module's QuickJS.o would otherwise collide.
    return join "\n", map {
        "qjs$_\$(OBJ_EXT): quickjs/$_.c @qjs_headers\n"
        . "\t\$(CCCMD) \$(CCCDLFLAGS) \$(DEFINE) -o \$\@ quickjs/$_.c\n"
    } @qjs_sources;
}

1;
