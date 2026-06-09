#!/usr/bin/perl
# t/unit.t -- black-box unit tests derived strictly from POD documentation.
# Only public interface is exercised: import(), :Private attribute, $BYPASS, %config.

use strict;
use warnings;

use Test::Most;
use Scalar::Util qw(reftype);
use Readonly;

BEGIN { $Sub::Private::config{mode} = 'enforce' }
use Sub::Private;

my $have_returns     = eval { require Test::Returns; Test::Returns->import; 1 };
my $have_mockingbird = eval { require Test::Mockingbird; Test::Mockingbird->import; 1 };

Readonly::Scalar my $SP         => 'Sub::Private';
Readonly::Scalar my $ATTR_OWNER => 'UT::AttrOwner';
Readonly::Scalar my $DECL_OWNER => 'UT::DeclOwner';

my %config = (
	attr_result    => 'attr_secret',
	decl_result    => 'decl_secret',
	invalid_digit  => '123bad',
	invalid_hyphen => 'has-hyphen',
	invalid_empty  => q{},
);

# -------------------------------------------------------------------
# Package fixtures
# -------------------------------------------------------------------

{
	package UT::AttrOwner;
	use Sub::Private;

	sub new           { bless {}, shift }
	sub _attr_secret  :Private { 'attr_secret' }
	sub call_secret   { (shift)->_attr_secret }
}

{
	package UT::AttrChild;
	our @ISA = ('UT::AttrOwner');
	sub new        { bless {}, shift }
	sub try_secret { (shift)->_attr_secret }  # defined in subclass context -- must be blocked
}

{
	package UT::AttrStranger;
	sub new   { bless {}, shift }
	sub probe { UT::AttrOwner->new->_attr_secret }
}

{
	package UT::DeclOwner;
	use Sub::Private qw(_decl_secret);

	sub new          { bless {}, shift }
	sub _decl_secret { 'decl_secret' }
	sub call_secret  { (shift)->_decl_secret }
}

{
	package UT::DeclStranger;
	sub new   { bless {}, shift }
	sub probe { UT::DeclOwner->new->_decl_secret }
}

{
	package UT::MultiDecl;
	use Sub::Private qw(_alpha _beta);

	sub new    { bless {}, shift }
	sub _alpha { 'alpha' }
	sub _beta  { 'beta'  }
	sub get_alpha { (shift)->_alpha }
	sub get_beta  { (shift)->_beta  }
}

diag "Black-box unit tests for $SP" if $ENV{TEST_VERBOSE};

# ===================================================================
# SECTION 1: import() with no arguments
# ===================================================================

subtest 'import(): no-args returns the class name' => sub {
	plan tests => $have_returns ? 2 : 1;

	my $result = Sub::Private->import();
	is $result, $SP, 'import() returns the class name';
	returns_ok($result, { type => 'string' }, 'return satisfies string schema')
		if $have_returns;
};

# ===================================================================
# SECTION 2: import() identifier validation
# ===================================================================

subtest 'import(): rejects identifier starting with a digit' => sub {
	plan tests => 2;

	my $bad = $config{invalid_digit};
	throws_ok {
		Sub::Private->import($bad)
	} qr/\Q$SP\E->import: '\Q$bad\E' is not a valid Perl identifier/,
		'digit-start identifier croaks with exact documented message';

	my $err;
	eval { Sub::Private->import($bad) };
	$err = $@;
	like $err, qr/is not a valid Perl identifier/, 'error contains required phrase';
};

subtest 'import(): rejects identifier containing a hyphen' => sub {
	plan tests => 1;

	my $bad = $config{invalid_hyphen};
	throws_ok {
		Sub::Private->import($bad)
	} qr/\Q$SP\E->import: '\Q$bad\E' is not a valid Perl identifier/,
		'hyphen-containing identifier croaks with exact documented message';
};

subtest 'import(): rejects empty-string identifier' => sub {
	plan tests => 1;
	throws_ok { Sub::Private->import($config{invalid_empty}) }
		qr/is not a valid Perl identifier/, 'empty-string identifier croaks';
};

subtest 'import(): undef sub name is rejected with documented error' => sub {
	plan tests => 1;
	throws_ok { Sub::Private->import(undef) }
		qr/is not a valid Perl identifier/,
		'import(undef) croaks with "not a valid Perl identifier"';
};

# ===================================================================
# SECTION 3: import() with non-existent sub
# ===================================================================

subtest 'import(): croaks with documented message for non-existent sub' => sub {
	plan tests => 2;
	local $Sub::Private::BYPASS = 1;

	my $nonexistent = '_no_such_sub_xyz';
	throws_ok {
		package UT::AttrOwner;
		Sub::Private->import($nonexistent);
	} qr/\Q$SP\E: \Q$ATTR_OWNER\E::\Q$nonexistent\E is not defined/,
		'non-existent sub croaks with exact documented message';

	my $err;
	{ local $Sub::Private::BYPASS = 1;
	  eval { package UT::AttrOwner; Sub::Private->import($nonexistent); };
	  $err = $@; }
	like $err, qr/is not defined/, 'error contains "is not defined"';
};

# ===================================================================
# SECTION 4: import() with namespace mode
# ===================================================================

subtest 'import(): declarative form with namespace mode croaks' => sub {
	plan tests => 1;
	local $Sub::Private::config{mode} = 'namespace';

	throws_ok { Sub::Private->import('_any') }
		qr/declarative form requires mode => 'enforce'/,
		'declarative form with namespace mode produces documented error';
};

# ===================================================================
# SECTION 5: :Private attribute form
# ===================================================================

subtest 'attribute form: owner can call a private sub' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = UT::AttrOwner->new->call_secret }
		'attribute form: owner allowed';
	is $result, $config{attr_result}, 'correct return value';
};

subtest 'attribute form: subclass is BLOCKED when calling from subclass context' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	# try_secret is defined in UT::AttrChild; caller check sees UT::AttrChild != owner
	throws_ok { UT::AttrChild->new->try_secret }
		qr/private subroutine/,
		'attribute form: subclass blocked (private = owner only)';
};

subtest 'attribute form: unrelated package is blocked' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { UT::AttrStranger->new->probe }
		qr/private subroutine/, 'attribute form: stranger blocked';
};

# ===================================================================
# SECTION 6: Declarative form
# ===================================================================

subtest 'declarative form: owner can call a private sub' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = UT::DeclOwner->new->call_secret }
		'declarative form: owner allowed';
	is $result, $config{decl_result}, 'correct return value';
};

subtest 'declarative form: unrelated package is blocked' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { UT::DeclStranger->new->probe }
		qr/private subroutine/, 'declarative form: stranger blocked';
};

subtest 'declarative form: multiple sub names wrapped in one import()' => sub {
	plan tests => 4;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my ($ra, $rb);
	lives_ok { $ra = UT::MultiDecl->new->get_alpha } 'owner: _alpha accessible';
	lives_ok { $rb = UT::MultiDecl->new->get_beta  } 'owner: _beta accessible';

	throws_ok { UT::MultiDecl::_alpha(UT::MultiDecl->new) }
		qr/private subroutine/, 'stranger: _alpha blocked';
	throws_ok { UT::MultiDecl::_beta(UT::MultiDecl->new) }
		qr/private subroutine/, 'stranger: _beta blocked';
};

# ===================================================================
# SECTION 7: Error message format
# ===================================================================

subtest 'error message matches the documented format' => sub {
	plan tests => 3;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $err;
	eval { UT::AttrStranger->new->probe };
	$err = $@;

	like $err, qr/_attr_secret\(\)/,      'error contains sub name followed by ()';
	like $err, qr/is a private subroutine of \Q$ATTR_OWNER\E/, 'error contains owner';
	like $err, qr/and cannot be called from UT::AttrStranger/, 'error contains caller';

	diag "Actual error: $err" if $ENV{TEST_VERBOSE};
};

# ===================================================================
# SECTION 8: $BYPASS
# ===================================================================

subtest '$BYPASS=1 allows call from any package' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 1;

	my $result;
	lives_ok { $result = UT::AttrStranger->new->probe }
		'$BYPASS=1: stranger is allowed';
	is $result, $config{attr_result}, 'correct value returned under BYPASS';
};

subtest '$BYPASS is restored after local scope exits' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE} = 0;

	{ local $Sub::Private::BYPASS = 1;
	  lives_ok { UT::AttrStranger->new->probe } '$BYPASS=1 active inside scope'; }

	throws_ok { UT::AttrStranger->new->probe }
		qr/private subroutine/, '$BYPASS restored to 0 after scope exits';
};

# ===================================================================
# SECTION 9: HARNESS_ACTIVE and %config{harness_bypass}
# ===================================================================

subtest 'HARNESS_ACTIVE=1 allows call from any package (default)' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 1;
	local $Sub::Private::BYPASS = 0;

	lives_ok { UT::AttrStranger->new->probe }
		'HARNESS_ACTIVE=1 bypasses access checks by default';
};

subtest 'config{harness_bypass}=0 disables the HARNESS_ACTIVE shortcut' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}                   = 1;
	local $Sub::Private::BYPASS                  = 0;
	local $Sub::Private::config{harness_bypass}  = 0;

	throws_ok { UT::AttrStranger->new->probe }
		qr/private subroutine/,
		'harness_bypass=0: HARNESS_ACTIVE no longer bypasses checks';
};

subtest 'config{harness_bypass} defaults to 1' => sub {
	plan tests => 1;
	is $Sub::Private::config{harness_bypass}, 1,
		'%config{harness_bypass} default is 1 as documented';
};

# ===================================================================
# SECTION 10: POD/code consistency checks
# ===================================================================

subtest 'POD/code: $BYPASS default value matches documentation' => sub {
	plan tests => 1;
	is $Sub::Private::BYPASS, 0, '$BYPASS starts at 0 as documented';
};

subtest 'POD/code: error message format matches documented template' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { UT::AttrStranger->new->probe }
		qr/\w+\(\) is a private subroutine of \w[\w:]* and cannot be called from \w[\w:]*/,
		'error message structure matches the documented template';
};

subtest 'POD/code: import() accepts leading-underscore identifiers' => sub {
	plan tests => 1;

	lives_ok {
		package UT::LeadingUnderscore;
		sub _valid_name { 1 }
		Sub::Private->import('_valid_name');
	} 'identifier starting with _ is accepted by import()';
};

subtest 'POD/code: BYPASS or HARNESS_ACTIVE OR logic (either alone is sufficient)' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { UT::AttrStranger->new->probe }
		qr/private subroutine/, 'both off: access enforced';

	{ local $Sub::Private::BYPASS = 1;
	  lives_ok { UT::AttrStranger->new->probe }
		'BYPASS alone (HARNESS_ACTIVE=0) is sufficient to bypass'; }
};

done_testing;
