# NAME

JavaScript::QuickJS - Run JavaScript via [QuickJS](https://bellard.org/quickjs) in Perl

# SYNOPSIS

Quick and dirty …

    my $val = JavaScript::QuickJS->new()->eval( q<
        console.log("Hello, Perl!");
        [ "The", "last", "value", "is", "returned." ];
    > );

# DESCRIPTION

This library embeds Fabrice Bellard’s QuickJS
engine into Perl. You can thus run JavaScript directly in your Perl programs.

This distribution includes QuickJS and builds it as part of building this
module.

# TYPE CONVERSION

This module converts returned values from JavaScript thus:

- JS strings become _character_ strings in Perl.
- JS numbers & booleans become corresponding Perl values.
- JS null & undefined become Perl undef.
- JS objects …
    - Arrays become Perl array references.
    - Functions trigger an exception. (TODO: Make those a Perl coderef.)
    - Other JS objects become Perl hashes.

# PLATFORM NOTES

QuickJS only seems to envision running on a fairly limited set of OSes.
As a result …

Linux & macOS are the only known platforms that work “out-of-the-box”.

Cygwin and FreeBSD _can_ work with some small tweaks to quickjs; see the
compiler errors and `quickjs.c` for more.

Other POSIX platforms _may_ work.

# METHODS

For now only a static interface is provided:

## $obj = _CLASS_->new()

Instantiates _CLASS_.

## $obj = _OBJ_->std()

Enables (but does _not_ import) QuickJS’s `std` module.

## $obj = _OBJ_->os()

Like `std()` but for QuickJS’s `os` module.

## $obj = _OBJ_->helpers()

Defines QuickJS’s “helpers”, e.g., `console.log`.

## $VALUE = eval( $JS\_CODE )

Comparable to running `qjs -e '...'`. Returns the last value from $JS\_CODE.

Untrapped exception in JavaScript will be rethrown as Perl exceptions.

## eval\_module( $JS\_CODE )

Runs $JS\_CODE as a module, which enables ES6 module syntax.
Note that no values can be returned directly in this mode of execution.
