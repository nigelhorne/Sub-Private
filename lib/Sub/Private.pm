package Sub::Private;

# Minimum Perl version: 5.8 (Attribute::Handlers became core in 5.8)
use 5.008;
use strict;
use warnings;
use autodie qw(:all);

use Attribute::Handlers;
use Carp              qw(croak carp);
use Readonly;
use Scalar::Util      qw(blessed);
use Params::Get       qw(get_params);
use Params::Validate::Strict 0.33 qw(validate_strict);
use Return::Set       qw(set_return);

use namespace::clean     qw();
use B::Hooks::EndOfScope qw(on_scope_end);
use Sub::Identify        qw(get_code_info);

=head1 NAME

Sub::Private - Private subroutines and methods

=head1 VERSION

Version 0.04

=cut

our $VERSION = '0.04';

=head1 SYNOPSIS

    package Foo;
    use Sub::Private;

    sub foo { return 42 }

    sub bar :Private {
        return foo() + 1;
    }

    sub baz {
        return bar() + 1;
    }

=head1 DESCRIPTION

Enforces truly private access on subroutines.  A subroutine decorated with
C<:Private> (or named in C<use Sub::Private qw(...)> when in enforce mode)
may only be called from within its defining package.  Subclasses do not
inherit access -- private means I<this package only>.

=head2 Two enforcement modes

=over 4

=item C<namespace> mode (default, backward-compatible)

Removes the subroutine from the package symbol table using
L<namespace::clean>.  Direct (non-method) function calls compiled before
cleanup still work because Perl optimises them to direct opcode references.
OO method dispatch (C<$self->name>) does not work for private subs in this
mode because it looks up the symbol table at runtime.

This is the default mode and is backward-compatible with all existing code.

=item C<enforce> mode (OO-safe, opt-in)

Replaces the subroutine with a wrapper closure that checks C<caller> at
call time and either delegates (owner package) or croaks (anyone else).
Works correctly with OO dispatch (C<$self->_helper>).

Enable before declaring your first private sub:

    $Sub::Private::config{mode} = 'enforce';
    package MyClass;
    use Sub::Private;
    sub _helper :Private { ... }

=back

=head2 Bypass for testing

Either condition alone (OR logic) disables all access checks in enforce mode:

=over 4

=item * C<$Sub::Private::BYPASS> set to a true value.  Use C<local> in tests.

=item * C<$ENV{HARNESS_ACTIVE}> set (the convention used by L<Test::Harness>/prove).

=back

C<$Sub::Private::BYPASS> is the recommended form for new test code.
The C<HARNESS_ACTIVE> bypass can be disabled:

    $Sub::Private::config{harness_bypass} = 0;

=head2 Configuration

    $Sub::Private::config{mode}            -- 'namespace' (default) or 'enforce'
    $Sub::Private::config{harness_bypass}  -- 1 (default); set to 0 to test enforcement

=head2 Error message format (enforce mode)

    bar() is a private subroutine of Foo and cannot be called from Bar

=head1 PUBLIC VARIABLES

=head2 C<$BYPASS>

Set to a true value to disable all access checks (enforce mode only).
Use C<local> in tests; see BYPASS section.

=head2 C<%config>

Module-level configuration hash.  Supported keys:

=over 4

=item C<mode>

C<'namespace'> (default) or C<'enforce'>.

=item C<harness_bypass>

When true (default), access checks are skipped whenever
C<$ENV{HARNESS_ACTIVE}> is set.

=back

=cut

# Public bypass flag.  Use C<local $Sub::Private::BYPASS = 1> in test code.
our $BYPASS = 0;

# Module-level configuration hash.  Use //= so that values set via a BEGIN
# block in the caller (e.g. BEGIN { $Sub::Private::config{mode}='enforce' })
# are not overwritten when the module body runs.
our %config;
$config{mode}           //= 'namespace';  # 'namespace' | 'enforce'
$config{harness_bypass} //= 1;

# Self-referential constant: the name of this package.
Readonly::Scalar my $SELF => __PACKAGE__;

# Validation schema for a single Perl sub name passed to import().
Readonly::Scalar my $SUB_NAME_SCHEMA => {
	name => {
		type  => 'string',
		regex => qr/\A[_a-zA-Z]\w*\z/,
	}
};

# Pending (owner_pkg, sub_name) pairs to be wrapped at CHECK time.
# Populated by import(); consumed and cleared by the CHECK block.
my @_pending;

# Set to 1 when the CHECK block fires.
my $_post_check = 0;

# -------------------------------------------------------------------
# ATTRIBUTE HANDLER
# -------------------------------------------------------------------

# Install the :Private attribute in UNIVERSAL so every package can use it
# the moment this module is loaded, with no per-package setup needed.
sub UNIVERSAL::Private :ATTR(CODE,CHECK) {
	my ($package, $symbol, $referent, $attr, $data) = @_;
	my $sub_name = *{$symbol}{NAME};

	if ($config{mode} eq 'enforce') {
		no warnings 'redefine';
		*{$symbol} = _wrap($package, $sub_name, $referent);  # function call, not method call
	} else {
		# At CHECK time the sub is fully compiled so direct cleanup is safe.
		# on_scope_end does not behave correctly when called from CHECK phase.
		namespace::clean->clean_subroutines( get_code_info($referent) );
	}
	return;
}

# -------------------------------------------------------------------
# PUBLIC INTERFACE
# -------------------------------------------------------------------

=head1 PUBLIC INTERFACE

=head2 import

    use Sub::Private;                    # attribute form -- no arguments
    use Sub::Private qw(_a _b _c);      # declarative form (enforce mode only)

=head3 Purpose

Called automatically by C<use Sub::Private>.

With B<no arguments>: makes the C<:Private> attribute globally available.

With B<one or more sub names>: registers those subs in the calling package
for wrapping at C<CHECK> time (or immediately if past C<CHECK>).  Requires
C<$Sub::Private::config{mode}> to be C<'enforce'>; croaks otherwise.

=head3 MESSAGES

    Message                                         Meaning
    -----------------------------------------------  ----------------------------------
    "Sub::Private->import: declarative form          use Sub::Private qw(...) attempted
     requires mode => 'enforce'"                     while mode is 'namespace'.  Set
                                                     $config{mode} = 'enforce' first.

    "Sub::Private->import: 'NAME' is not a           A sub name failed the identifier
     valid Perl identifier"                          regex /\A[_a-zA-Z]\w*\z/.

    "Sub::Private: PKG::NAME is not defined"         Named sub not found at wrap time.

=cut

sub import {
	my ($class, @subs) = @_;

	# No sub names: the :Private attribute is always active via UNIVERSAL.
	return set_return($class, { type => 'string' }) unless @subs;

	# Declarative form only valid in enforce mode.
	croak "$SELF->import: declarative form requires mode => 'enforce'"
		if $config{mode} ne 'enforce';

	# Normalise the argument list.
	my $args = get_params('subs', \@subs);
	my @names = ref($args->{subs}) eq 'ARRAY'
		? @{$args->{subs}}
		: ($args->{subs});

	# Validate each name against the schema.
	for my $sub_name (@names) {
		my $check = (defined $sub_name && !ref $sub_name) ? $sub_name : q{};
		eval { validate_strict(schema => $SUB_NAME_SCHEMA, input => { name => $check }) };
		croak "$SELF->import: '$check' is not a valid Perl identifier"
			if $@;
	}

	# Schedule or immediately apply wrapping depending on compilation phase.
	my $owner_pkg = caller;
	if ($_post_check) {
		_process_one($owner_pkg, $_) for @names;
	} else {
		push @_pending, [ $owner_pkg, $_ ] for @names;
	}

	return set_return($class, { type => 'string' });
}

# -------------------------------------------------------------------
# CHECK-TIME PROCESSING
# -------------------------------------------------------------------

# Process all pending declarative wraps registered during import().
CHECK {
	$_post_check = 1;
	_process_one(@$_) for @_pending;
	@_pending = ();
}

# -------------------------------------------------------------------
# PRIVATE SUBROUTINES
# -------------------------------------------------------------------

# _process_one
# Look up a named sub in a package's stash and wrap it.
# Called from the CHECK block and from import() (post-CHECK).
sub _process_one {
	my ($owner_pkg, $sub_name) = @_;

	_assert_private_caller('_process_one')
		unless $BYPASS || ($config{harness_bypass} && $ENV{HARNESS_ACTIVE});

	no strict 'refs';

	croak "$SELF: ${owner_pkg}::${sub_name} is not defined"
		unless defined &{"${owner_pkg}::${sub_name}"};

	my $code = \&{"${owner_pkg}::${sub_name}"};
	no warnings 'redefine';
	*{"${owner_pkg}::${sub_name}"} = _wrap($owner_pkg, $sub_name, $code);
	return;
}

# _wrap
# Construct the enforcement wrapper closure around a coderef.
# 'goto &$code' replaces the wrapper's stack frame with $code's frame so
# that caller() inside the private sub sees the real caller, not Sub::Private.
sub _wrap {
	my ($owner_pkg, $sub_name, $code) = @_;

	_assert_private_caller('_wrap')
		unless $BYPASS || ($config{harness_bypass} && $ENV{HARNESS_ACTIVE});

	return sub {
		Sub::Private::_check_access($owner_pkg, $sub_name);
		goto &$code;    ## no critic (ControlStructures::ProhibitGoto)
	};
}

# _check_access
# Enforce the private-access invariant at call time.
# Unlike Sub::Protected, there is NO ->isa check: private means the owner
# package ONLY.  Subclasses do not inherit access to parent private subs.
sub _check_access {
	my ($owner_pkg, $sub_name) = @_;

	return if $BYPASS;
	return if $config{harness_bypass} && $ENV{HARNESS_ACTIVE};

	my $frame = 0;
	while (1) {
		my $pkg = (caller($frame))[0];

		if (!defined $pkg) {
			croak "${sub_name}() is a private subroutine of ${owner_pkg}"
				. ' and cannot be called outside any package context';
		}

		if ($pkg eq $SELF) { $frame++; next }

		# Private: ONLY the owner package is allowed -- no subclass allowance.
		return if $pkg eq $owner_pkg;

		croak "${sub_name}() is a private subroutine of ${owner_pkg}"
			. " and cannot be called from ${pkg}";
	}
}

# _assert_private_caller
# Croak if the guarded private method was called from outside Sub::Private.
sub _assert_private_caller {
	my ($method_name) = @_;

	my $caller = (caller(1))[0] // q{};
	return if $caller eq $SELF || eval { $caller->isa($SELF) };

	croak "${method_name}() is a private method of $SELF"
		. " and cannot be called from ${caller}";
}

1;

__END__

=head1 KNOWN LIMITATIONS

=over 4

=item C<namespace> mode: OO dispatch fails for private subs

C<$self->_helper> from within the owner package fails because method dispatch
uses the symbol table at runtime, which no longer contains the entry.  Use
C<enforce> mode for OO classes.

=item C<enforce> mode: runtime-only

Checks are runtime only; there is no compile-time enforcement.

=item C<enforce> mode: raw coderef bypass

A raw code reference obtained B<before> wrapping (via C<can()> or
C<\&Foo::_helper>) bypasses the check.  The attribute form prevents this
because wrapping happens at compile (CHECK) time.

=item UNIVERSAL namespace pollution

The C<:Private> attribute is installed in C<UNIVERSAL>, which is
intentional (any package can use it after a single C<use>), but it does
introduce C<UNIVERSAL::Private> into the global namespace.

=back

=head1 DEPENDENCIES

L<Carp> (core),
L<Attribute::Handlers> (core since 5.8),
L<Readonly>,
L<Scalar::Util> (core),
L<Params::Get>,
L<Params::Validate::Strict>,
L<Return::Set>,
L<namespace::clean>,
L<B::Hooks::EndOfScope>,
L<Sub::Identify>.

=head1 SEE ALSO

L<namespace::clean>,
L<Sub::Protected> -- sister module enforcing protected (owner + subclass)
rather than strictly private access.

=head2 FORMAL SPECIFICATION

The following Z-notation schemas formally specify the C<CheckAccess> operation.

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

=head1 AUTHOR

Original Author:
Peter Makholm, C<< <peter at makholm.net> >>

Current maintainer:
Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-sub-private at rt.cpan.org>,
or through the web interface at
L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sub-Private>.

=head1 SUPPORT

    perldoc Sub::Private

=over 4

=item * RT: CPAN's request tracker

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=Sub-Private>

=item * Search CPAN

L<https://search.cpan.org/dist/Sub-Private>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2009 Peter Makholm, all rights reserved.
Portions copyright 2024-2026 Nigel Horne.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
