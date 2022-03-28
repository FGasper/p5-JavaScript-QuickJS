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

# TYPE CONVERSION: JAVASCRIPT → PERL

This module converts returned values from JavaScript thus:

- JS string primitives become _character_ strings in Perl.
- JS number & boolean primitives become corresponding Perl values.
- JS null & undefined become Perl undef.
- JS objects …
    - Arrays become Perl array references.
    - “Plain” objects become Perl hash references.
    - Behaviour is **UNDEFINED** for other object types.

# TYPE CONVERSION: PERL → JAVASCRIPT

Generally speaking, it’s the inverse of JS → Perl, though of course
since Perl doesn’t differentiate “numeric strings” from “numbers” there’s
occasional ambiguity. In such cases, behavior is undefined; be sure to
typecast in JavaScript accordingly!

- Perl strings, numbers, & booleans become corresponding JavaScript
primitives.
- Perl undef becomes JS null.
- Unblessed array & hash references become JavaScript arrays and
“plain” objects.
- Perl code references become JavaScript functions.
- Anything else triggers an exception.

# PLATFORM NOTES

Due to QuickJS limitations, Linux & macOS are the only platforms known
to work “out-of-the-box”. Other POSIX OSes _should_ work with some small
tweaks to quickjs; see the compiler errors and `quickjs.c` for more
details.

Pull requests to improve portability are welcome!

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

# LICENSE & COPYRIGHT

Copyright 2019-2021 Gasper Software Consulting.

This library is licensed under the same terms as Perl itself.
