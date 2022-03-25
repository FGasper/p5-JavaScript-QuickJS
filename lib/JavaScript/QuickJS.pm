package JavaScript::QuickJS;

use strict;
use warnings;

=encoding utf-8

=head1 NAME

JavaScript::QuickJS

=head1 SYNOPSIS

Quick and dirty …

    my $val = JavaScript::QuickJS::run( q<
        console.log("Hello, Perl!");
        [ "The", "last", "value", "is", "returned." ];
    > );

=head1 DESCRIPTION

This library embeds Fabrice Bellard’s L<QuickJS|https://bellard.org/quickjs>
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

=cut

# ----------------------------------------------------------------------

use XSLoader;

our $VERSION = '0.01_01';

XSLoader::load( __PACKAGE__, $VERSION );

# ----------------------------------------------------------------------

=head1 FUNCTIONS

For now only a static interface is provided:

=head2 $VALUE = run( $JS_CODE )

Comparable to running C<qjs -e '...'>. The C<std> and C<os> modules
are I<available> but (unlike F<qjs>) not imported by default.

Returns the last value from $JS_CODE.

=cut

1;
