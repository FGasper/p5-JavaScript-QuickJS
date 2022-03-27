package JavaScript::QuickJS;

use strict;
use warnings;

=encoding utf-8

=head1 NAME

JavaScript::QuickJS - Run JavaScript via L<QuickJS|https://bellard.org/quickjs> in Perl

=head1 SYNOPSIS

Quick and dirty …

    my $val = JavaScript::QuickJS->new()->eval( q<
        console.log("Hello, Perl!");
        [ "The", "last", "value", "is", "returned." ];
    > );

=head1 DESCRIPTION

This library embeds Fabrice Bellard’s QuickJS
engine into Perl. You can thus run JavaScript directly in your Perl programs.

This distribution includes QuickJS and builds it as part of building this
module.

=head1 TYPE CONVERSION

This module converts returned values from JavaScript thus:

=over

=item * JS strings become I<character> strings in Perl.

=item * JS numbers & booleans become corresponding Perl values.

=item * JS null & undefined become Perl undef.

=item * JS objects …

=over

=item * Arrays become Perl array references.

=item * Functions trigger an exception. (TODO: Make those a Perl coderef.)

=item * Other JS objects become Perl hashes.

=back

=back

=head1 PLATFORM NOTES

QuickJS only seems to envision running on a fairly limited set of OSes.
As a result …

Linux & macOS are the only known platforms that work “out-of-the-box”.

Cygwin and FreeBSD I<can> work with some small tweaks to quickjs; see the
compiler errors and F<quickjs.c> for more.

Other POSIX platforms I<may> work.

=cut

# ----------------------------------------------------------------------

use XSLoader;

our $VERSION = '0.01_01';

XSLoader::load( __PACKAGE__, $VERSION );

# ----------------------------------------------------------------------

=head1 METHODS

For now only a static interface is provided:

=head2 $obj = I<CLASS>->new()

Instantiates I<CLASS>.

=head2 $obj = I<OBJ>->std()

Enables (but does I<not> import) QuickJS’s C<std> module.

=head2 $obj = I<OBJ>->os()

Like C<std()> but for QuickJS’s C<os> module.

=head2 $obj = I<OBJ>->helpers()

Defines QuickJS’s “helpers”, e.g., C<console.log>.

=head2 $VALUE = eval( $JS_CODE )

Comparable to running C<qjs -e '...'>. Returns the last value from $JS_CODE.

Untrapped exception in JavaScript will be rethrown as Perl exceptions.

=head2 eval_module( $JS_CODE )

Runs $JS_CODE as a module, which enables ES6 module syntax.
Note that no values can be returned directly in this mode of execution.

=cut

1;
