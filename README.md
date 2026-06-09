# NAME

Sub::Private - Private subroutines and methods

# VERSION

Version 0.04

# SYNOPSIS

    package Foo;
    use Sub::Private;

    sub foo { return 42 }

    sub bar :Private {
        return foo() + 1;
    }

    sub baz {
        return bar() + 1;
    }

# DESCRIPTION

Enforces truly private access on subroutines.  A subroutine decorated with
`:Private` (or named in `use Sub::Private qw(...)` when in enforce mode)
may only be called from within its defining package.  Subclasses do not
inherit access -- private means _this package only_.

## Two enforcement modes

- `namespace` mode (default, backward-compatible)

    Removes the subroutine from the package symbol table using
    [namespace::clean](https://metacpan.org/pod/namespace%3A%3Aclean).  Direct (non-method) function calls compiled before
    cleanup still work because Perl optimises them to direct opcode references.
    OO method dispatch (`$self-`name>) does not work for private subs in this
    mode because it looks up the symbol table at runtime.

    This is the default mode and is backward-compatible with all existing code.

- `enforce` mode (OO-safe, opt-in)

    Replaces the subroutine with a wrapper closure that checks `caller` at
    call time and either delegates (owner package) or croaks (anyone else).
    Works correctly with OO dispatch (`$self-`\_helper>).

    Enable before declaring your first private sub:

        $Sub::Private::config{mode} = 'enforce';
        package MyClass;
        use Sub::Private;
        sub _helper :Private { ... }

## Bypass for testing

Either condition alone (OR logic) disables all access checks in enforce mode:

- `$Sub::Private::BYPASS` set to a true value.  Use `local` in tests.
- `$ENV{HARNESS_ACTIVE}` set (the convention used by [Test::Harness](https://metacpan.org/pod/Test%3A%3AHarness)/prove).

`$Sub::Private::BYPASS` is the recommended form for new test code.
The `HARNESS_ACTIVE` bypass can be disabled:

    $Sub::Private::config{harness_bypass} = 0;

## Configuration

    $Sub::Private::config{mode}            -- 'namespace' (default) or 'enforce'
    $Sub::Private::config{harness_bypass}  -- 1 (default); set to 0 to test enforcement

## Error message format (enforce mode)

    bar() is a private subroutine of Foo and cannot be called from Bar

# PUBLIC VARIABLES

## `$BYPASS`

Set to a true value to disable all access checks (enforce mode only).
Use `local` in tests; see BYPASS section.

## `%config`

Module-level configuration hash.  Supported keys:

- `mode`

    `'namespace'` (default) or `'enforce'`.

- `harness_bypass`

    When true (default), access checks are skipped whenever
    `$ENV{HARNESS_ACTIVE}` is set.

# PUBLIC INTERFACE

## import

    use Sub::Private;                    # attribute form -- no arguments
    use Sub::Private qw(_a _b _c);      # declarative form (enforce mode only)

### Purpose

Called automatically by `use Sub::Private`.

With **no arguments**: makes the `:Private` attribute globally available.

With **one or more sub names**: registers those subs in the calling package
for wrapping at `CHECK` time (or immediately if past `CHECK`).  Requires
`$Sub::Private::config{mode}` to be `'enforce'`; croaks otherwise.

### MESSAGES

    Message                                         Meaning
    -----------------------------------------------  ----------------------------------
    "Sub::Private->import: declarative form          use Sub::Private qw(...) attempted
     requires mode => 'enforce'"                     while mode is 'namespace'.  Set
                                                     $config{mode} = 'enforce' first.

    "Sub::Private->import: 'NAME' is not a           A sub name failed the identifier
     valid Perl identifier"                          regex /\A[_a-zA-Z]\w*\z/.

    "Sub::Private: PKG::NAME is not defined"         Named sub not found at wrap time.

# KNOWN LIMITATIONS

- `namespace` mode: OO dispatch fails for private subs

    `$self-`\_helper> from within the owner package fails because method dispatch
    uses the symbol table at runtime, which no longer contains the entry.  Use
    `enforce` mode for OO classes.

- `enforce` mode: runtime-only

    Checks are runtime only; there is no compile-time enforcement.

- `enforce` mode: raw coderef bypass

    A raw code reference obtained **before** wrapping (via `can()` or
    `\&Foo::_helper`) bypasses the check.  The attribute form prevents this
    because wrapping happens at compile (CHECK) time.

- UNIVERSAL namespace pollution

    The `:Private` attribute is installed in `UNIVERSAL`, which is
    intentional (any package can use it after a single `use`), but it does
    introduce `UNIVERSAL::Private` into the global namespace.

# DEPENDENCIES

[Carp](https://metacpan.org/pod/Carp) (core),
[Attribute::Handlers](https://metacpan.org/pod/Attribute%3A%3AHandlers) (core since 5.8),
[Readonly](https://metacpan.org/pod/Readonly),
[Scalar::Util](https://metacpan.org/pod/Scalar%3A%3AUtil) (core),
[Params::Get](https://metacpan.org/pod/Params%3A%3AGet),
[Params::Validate::Strict](https://metacpan.org/pod/Params%3A%3AValidate%3A%3AStrict),
[Return::Set](https://metacpan.org/pod/Return%3A%3ASet),
[namespace::clean](https://metacpan.org/pod/namespace%3A%3Aclean),
[B::Hooks::EndOfScope](https://metacpan.org/pod/B%3A%3AHooks%3A%3AEndOfScope),
[Sub::Identify](https://metacpan.org/pod/Sub%3A%3AIdentify).

# SEE ALSO

[namespace::clean](https://metacpan.org/pod/namespace%3A%3Aclean),
[Sub::Protected](https://metacpan.org/pod/Sub%3A%3AProtected) -- sister module enforcing protected (owner + subclass)
rather than strictly private access.

## FORMAL SPECIFICATION

The following Z-notation schemas formally specify the `CheckAccess` operation.

    -- Type abbreviations
    Package  == seq CHAR     -- a non-empty Perl package name string
    SubName  == seq CHAR     -- a Perl identifier string

    -- Private-access predicate (strictly owner only -- no isa expansion)
    permitted : Package x Package -> BOOL
    forall caller, owner : Package .
        permitted(caller, owner) <=> caller = owner

    -- System state
    +-Registry-------------------------------------------+
    | private   : P (Package x SubName)                  |
    | bypass    : BOOL                                   |
    | config    : { mode : seq CHAR,                     |
    |               harness_bypass : BOOL }              |
    +----------------------------------------------------+

    -- Initial state
    +-InitRegistry---------------------------------------+
    | Registry                                           |
    |----------------------------------------------------|
    | private   = {}                                     |
    | bypass    = false                                  |
    | config    = { mode |-> 'namespace',                |
    |               harness_bypass |-> true }            |
    +----------------------------------------------------+

    -- Bypass predicate
    bypass_active(R) <=>
        R.bypass or (R.config.harness_bypass and HARNESS_ACTIVE)

    -- Access check: no state change
    +-CheckAccess----------------------------------------+
    | Xi-Registry                                        |
    | caller? : Package                                  |
    | owner?  : Package                                  |
    | name?   : SubName                                  |
    | ok!     : BOOL                                     |
    |----------------------------------------------------|
    | (owner?, name?) in private                         |
    | ok! <=> bypass_active or permitted(caller?, owner?)|
    +----------------------------------------------------+

    -- Violation (croak case):
    --   not ok! =>
    --   croak("name?()" ++ " is a private subroutine of " ++ owner?
    --         ++ " and cannot be called from " ++ caller?)

    -- Key difference from Sub::Protected:
    --   permitted(caller, owner) <=> caller = owner   (identity only)
    -- vs Sub::Protected:
    --   permitted(caller, owner) <=> owner in anc(caller)   (ISA chain)

# AUTHOR

Original Author:
Peter Makholm, `<peter at makholm.net>`

Current maintainer:
Nigel Horne, `<njh at nigelhorne.com>`

# BUGS

Please report any bugs or feature requests to `bug-sub-private at rt.cpan.org`,
or through the web interface at
[https://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sub-Private](https://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sub-Private).

# SUPPORT

    perldoc Sub::Private

- RT: CPAN's request tracker

    [https://rt.cpan.org/NoAuth/Bugs.html?Dist=Sub-Private](https://rt.cpan.org/NoAuth/Bugs.html?Dist=Sub-Private)

- Search CPAN

    [https://search.cpan.org/dist/Sub-Private](https://search.cpan.org/dist/Sub-Private)

# COPYRIGHT & LICENSE

Copyright 2009 Peter Makholm, all rights reserved.
Portions copyright 2024-2026 Nigel Horne.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.
