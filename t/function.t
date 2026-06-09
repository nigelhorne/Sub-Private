#!/usr/bin/perl
# t/function.t -- white-box function-level tests for Sub::Private

use strict;
use warnings;

use Test::Most;
use Scalar::Util qw(reftype);
use Readonly;

# Loading Sub::Private fires the CHECK block and sets $_post_check = 1.
# Set enforce mode before loading so attribute-form fixtures use it.
BEGIN { $Sub::Private::config{mode} = 'enforce' }
use Sub::Private;

# Use Test::Mockingbird and Test::Returns only if available.
my $have_mockingbird = eval { require Test::Mockingbird; Test::Mockingbird->import; 1 };
my $have_returns     = eval { require Test::Returns; Test::Returns->import; 1 };

# -------------------------------------------------------------------
# Constants
# -------------------------------------------------------------------

Readonly::Scalar my $SP       => 'Sub::Private';
Readonly::Scalar my $OWNER    => 'FT::Owner';
Readonly::Scalar my $CHILD    => 'FT::Child';
Readonly::Scalar my $STRANGER => 'FT::Stranger';
Readonly::Scalar my $CHK_PKG  => 'FT::CheckOwner';
Readonly::Scalar my $CHK_SUB  => 'chk_fn';

my %config = (
	valid_sub        => '_secret',
	proc_sub         => '_proc_target',
	nonexistent_sub  => '_ft_nonexistent_xyz',
	invalid_digit    => '123bad',
	invalid_hyphen   => 'has-hyphen',
	invalid_empty    => q{},
	secret_result    => 'secret',
	proc_result      => 'proc',
);

# -------------------------------------------------------------------
# Package fixtures
# -------------------------------------------------------------------

{
	package FT::Owner;
	use Sub::Private;

	sub new             { bless {}, shift }
	sub _secret         :Private { 'secret' }
	sub _bare_unwrapped { 'bare' }
	sub _proc_target    { 'proc' }
	sub call_secret     { (shift)->_secret }
	sub call_fn         { my (undef, $fn) = @_; $fn->() }
}

{
	package FT::Child;
	our @ISA = ('FT::Owner');
	sub new        { bless {}, shift }
	sub try_secret { (shift)->_secret }  # defined in subclass context -- must be blocked
}

{
	package FT::Stranger;
	sub new   { bless {}, shift }
	sub probe { FT::Owner->new->_secret }
}

# Fixtures for _check_access() direct testing.
{
	package FT::CheckOwner;
	sub call_check { Sub::Private::_check_access('FT::CheckOwner', 'chk_fn') }
}

{
	package FT::CheckChild;
	our @ISA = ('FT::CheckOwner');
	sub call_check { Sub::Private::_check_access('FT::CheckOwner', 'chk_fn') }
}

{
	package FT::CheckStranger;
	sub call_check { Sub::Private::_check_access('FT::CheckOwner', 'chk_fn') }
}

# Fixtures for _assert_private_caller() testing.
{
	package FT::External;
	sub try_assert { Sub::Private::_assert_private_caller('_test_method') }
}

# Two-level chain inside Sub::Private's own namespace (enables the allow path).
{
	package Sub::Private;
	sub _ft_inner_assert { Sub::Private::_assert_private_caller('_ft_inner_assert') }
	sub _ft_outer_assert { Sub::Private::_ft_inner_assert() }
}

# Post-CHECK declarative wrapping fixture.
{
	package FT::ImportTarget;
	sub _importable { 'importable' }
	Sub::Private->import('_importable');
}

diag "Starting white-box function tests for $SP" if $ENV{TEST_VERBOSE};

# ===================================================================
# SECTION 1: import()
# ===================================================================

subtest 'import(): no-args returns the class name' => sub {
	plan tests => $have_returns ? 2 : 1;

	my $result = Sub::Private->import();
	is $result, $SP, 'import() returns the class name';
	returns_ok($result, { type => 'string' }, 'return value satisfies string schema')
		if $have_returns;
};

subtest 'import(): rejects identifier starting with a digit' => sub {
	plan tests => 1;
	throws_ok { Sub::Private->import($config{invalid_digit}) }
		qr/is not a valid Perl identifier/,
		'digit-start identifier croaks';
};

subtest 'import(): rejects identifier containing a hyphen' => sub {
	plan tests => 1;
	throws_ok { Sub::Private->import($config{invalid_hyphen}) }
		qr/is not a valid Perl identifier/,
		'hyphen identifier croaks';
};

subtest 'import(): rejects empty-string identifier' => sub {
	plan tests => 1;
	throws_ok { Sub::Private->import($config{invalid_empty}) }
		qr/is not a valid Perl identifier/,
		'empty string croaks';
};

subtest 'import(): croaks for non-existent sub (post-CHECK path)' => sub {
	plan tests => 1;
	local $Sub::Private::BYPASS = 1;
	throws_ok {
		package FT::ImportCroak;
		Sub::Private->import($config{nonexistent_sub});
	} qr/\Q$config{nonexistent_sub}\E is not defined/,
		'import() croaks when the named sub does not exist';
};

subtest 'import(): wrapped sub enforces access (post-CHECK)' => sub {
	plan tests => 3;
	local $ENV{HARNESS_ACTIVE}     = 0;
	local $Sub::Private::BYPASS    = 0;

	my $result;
	lives_ok {
		package FT::ImportTarget;
		$result = FT::ImportTarget::_importable();
	} 'import: owner can call wrapped sub';
	is $result, 'importable', 'correct return value from wrapped sub';

	throws_ok {
		package FT::ImportStranger;
		FT::ImportTarget::_importable();
	} qr/private subroutine/,
		'import: unrelated package blocked from wrapped sub';
};

# ===================================================================
# SECTION 2: _wrap()
# ===================================================================

subtest '_wrap(): private guard blocks call from outside Sub::Private' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok {
		Sub::Private::_wrap($OWNER, '_bare_unwrapped', sub { 1 })
	} qr/_wrap\(\) is a private method of \Q$SP\E/,
		'_wrap() croaks when called directly from main';
};

subtest '_wrap(): BYPASS=1 skips guard and returns a CODE ref' => sub {
	plan tests => 2;
	local $Sub::Private::BYPASS = 1;

	my $wrapper;
	lives_ok {
		$wrapper = Sub::Private::_wrap($OWNER, '_bare_unwrapped', sub { 42 });
	} '_wrap() lives when BYPASS=1';
	ok defined($wrapper) && reftype($wrapper) eq 'CODE', '_wrap() returns a CODE ref';
};

subtest '_wrap(): HARNESS_ACTIVE=1 skips guard and returns a CODE ref' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 1;
	local $Sub::Private::BYPASS = 0;

	my $wrapper;
	lives_ok {
		$wrapper = Sub::Private::_wrap($OWNER, '_bare_unwrapped', sub { 99 });
	} '_wrap() lives when HARNESS_ACTIVE=1';
	ok defined($wrapper) && reftype($wrapper) eq 'CODE', '_wrap() returns CODE ref';
};

subtest '_wrap(): returned closure allows call from owner package' => sub {
	plan tests => 2;

	my $wrapper;
	{ local $Sub::Private::BYPASS = 1;
	  $wrapper = Sub::Private::_wrap($OWNER, '_bare_unwrapped', sub { 'allowed' }); }

	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = FT::Owner->new->call_fn($wrapper) }
		'wrapper allows call via FT::Owner::call_fn';
	is $result, 'allowed', 'wrapper returns the original coderef result';
};

subtest '_wrap(): returned closure blocks call from unrelated package' => sub {
	plan tests => 1;

	my $wrapper;
	{ local $Sub::Private::BYPASS = 1;
	  $wrapper = Sub::Private::_wrap($OWNER, '_bare_unwrapped', sub { 1 }); }

	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok {
		package FT::WrapBlockTest;
		$wrapper->();
	} qr/_bare_unwrapped\(\) is a private subroutine of \Q$OWNER\E/,
		'wrapper blocks call from unrelated package';
};

subtest '_wrap(): returned closure has no circular references' => sub {
	plan tests => 1;

	SKIP: {
		skip 'Test::Memory::Cycle not available', 1
			unless eval { require Test::Memory::Cycle; 1 };
		Test::Memory::Cycle->import;

		local $Sub::Private::BYPASS = 1;
		my $wrapper = Sub::Private::_wrap($OWNER, '_bare_unwrapped', sub { 42 });
		memory_cycle_ok($wrapper, 'wrapper closure has no circular references');
	}
};

# ===================================================================
# SECTION 3: _check_access()
# ===================================================================

subtest '_check_access(): allows call from the owner package' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	lives_ok { FT::CheckOwner::call_check() }
		'_check_access() returns normally for the owner package';
};

subtest '_check_access(): BLOCKS call from a subclass (private != protected)' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { FT::CheckChild::call_check() }
		qr/private subroutine/,
		'_check_access() blocks subclass (no isa allowance -- private means owner only)';
};

subtest '_check_access(): blocks outsider with canonical error message' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $expected = qr/\Q$CHK_SUB\E\(\) is a private subroutine of \Q$CHK_PKG\E and cannot be called from FT::CheckStranger/;
	throws_ok { FT::CheckStranger::call_check() } $expected,
		'_check_access() croaks with canonical message format';

	my $err;
	eval { FT::CheckStranger::call_check() };
	$err = $@;
	like $err, qr/cannot be called from/, 'error contains "cannot be called from"';
};

subtest '_check_access(): BYPASS=1 short-circuits all checks' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 1;

	lives_ok { FT::CheckStranger::call_check() }
		'_check_access() short-circuits when BYPASS=1';
};

subtest '_check_access(): HARNESS_ACTIVE=1 short-circuits all checks' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 1;
	local $Sub::Private::BYPASS = 0;

	lives_ok { FT::CheckStranger::call_check() }
		'_check_access() short-circuits when HARNESS_ACTIVE=1';
};

subtest '_check_access(): harness_bypass=0 suppresses HARNESS_ACTIVE bypass' => sub {
	plan tests => 2;
	local $Sub::Private::config{harness_bypass} = 0;
	local $ENV{HARNESS_ACTIVE}                  = 1;
	local $Sub::Private::BYPASS                 = 0;

	lives_ok { FT::CheckOwner::call_check() }
		'_check_access() still allows owner when harness_bypass=0';

	throws_ok { FT::CheckStranger::call_check() }
		qr/private subroutine/,
		'_check_access() still blocks stranger when harness_bypass=0 + HARNESS_ACTIVE=1';
};

# ===================================================================
# SECTION 4: _process_one()
# ===================================================================

subtest '_process_one(): private guard blocks call from outside Sub::Private' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok {
		Sub::Private::_process_one($OWNER, $config{proc_sub})
	} qr/_process_one\(\) is a private method of \Q$SP\E/,
		'_process_one() croaks when called from main';
};

subtest '_process_one(): croaks when the named sub is not defined' => sub {
	plan tests => 1;
	local $Sub::Private::BYPASS = 1;

	throws_ok {
		Sub::Private::_process_one('FT::NoPkg', $config{nonexistent_sub})
	} qr/\Q$config{nonexistent_sub}\E is not defined/,
		'_process_one() croaks for an undefined sub';
};

subtest '_process_one(): installs a wrapper coderef in the stash' => sub {
	plan tests => 3;

	my $original = \&FT::Owner::_proc_target;
	{ local $Sub::Private::BYPASS = 1;
	  Sub::Private::_process_one($OWNER, $config{proc_sub}); }

	my $wrapped = \&FT::Owner::_proc_target;
	isnt $wrapped, $original, '_process_one() replaced the stash entry';
	ok defined($wrapped) && reftype($wrapped) eq 'CODE', 'replacement is a CODE ref';

	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok {
		$result = FT::Owner->new->call_fn(\&FT::Owner::_proc_target);
	} '_process_one: owner can call the wrapped sub via call_fn';
};

# ===================================================================
# SECTION 5: _assert_private_caller()
# ===================================================================

subtest '_assert_private_caller(): croaks when caller is not Sub::Private' => sub {
	plan tests => 2;

	throws_ok { FT::External::try_assert() }
		qr/_test_method\(\) is a private method of \Q$SP\E and cannot be called from/,
		'_assert_private_caller() croaks from non-Sub::Private context';

	my $err;
	eval { FT::External::try_assert() };
	$err = $@;
	like $err, qr/is a private method of \Q$SP\E/, 'error contains expected phrase';
};

subtest '_assert_private_caller(): allows when caller is Sub::Private' => sub {
	plan tests => 1;

	lives_ok { Sub::Private::_ft_outer_assert() }
		'_assert_private_caller() returns normally within a Sub::Private call chain';
};

# ===================================================================
# SECTION 6: Attribute handler
# ===================================================================

subtest 'attribute handler: wraps sub and enforces access' => sub {
	plan tests => 3;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = FT::Owner->new->call_secret }
		'attribute handler: owner can call its private sub';
	is $result, $config{secret_result}, 'private sub returns correct value';

	throws_ok { FT::Stranger->new->probe }
		qr/_secret\(\) is a private subroutine of \Q$OWNER\E/,
		'attribute handler: stranger blocked with canonical message';
};

subtest 'attribute handler: subclass is BLOCKED when calling from subclass context' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	# try_secret is defined in FT::Child; caller check sees FT::Child != FT::Owner
	throws_ok { FT::Child->new->try_secret }
		qr/private subroutine/,
		'attribute handler: subclass blocked (no isa allowance)';
};

# ===================================================================
# SECTION 7: harness_bypass=0 -- guards still fire with HARNESS_ACTIVE=1
# ===================================================================

subtest '_wrap(): guard fires even with HARNESS_ACTIVE=1 when harness_bypass=0' => sub {
	plan tests => 1;
	local $Sub::Private::config{harness_bypass} = 0;
	local $ENV{HARNESS_ACTIVE}                  = 1;
	local $Sub::Private::BYPASS                 = 0;

	throws_ok {
		Sub::Private::_wrap($OWNER, '_bare_unwrapped', sub { 1 });
	} qr/_wrap\(\) is a private method of \Q$SP\E/,
		'_wrap() guard fires when harness_bypass=0 and HARNESS_ACTIVE=1';
};

subtest '_process_one(): guard fires even with HARNESS_ACTIVE=1 when harness_bypass=0' => sub {
	plan tests => 1;
	local $Sub::Private::config{harness_bypass} = 0;
	local $ENV{HARNESS_ACTIVE}                  = 1;
	local $Sub::Private::BYPASS                 = 0;

	throws_ok {
		Sub::Private::_process_one($OWNER, $config{proc_sub});
	} qr/_process_one\(\) is a private method of \Q$SP\E/,
		'_process_one() guard fires when harness_bypass=0 and HARNESS_ACTIVE=1';
};

# ===================================================================
# SECTION 8: spy verification (if Test::Mockingbird available)
# ===================================================================

if ($have_mockingbird) {
	subtest 'import(): spy confirms validate_strict is called' => sub {
		plan tests => 1;

		# get_params was removed from import() (positional args need no normalisation).
		# validate_strict is still called once per sub name for identifier validation.
		my $spy_vs = Test::Mockingbird::spy('Sub::Private::validate_strict');

		{
			package FT::SpyTarget;
			sub _spy_sub { 'spied' }
			Sub::Private->import('_spy_sub');
		}

		my @vs_calls = $spy_vs->();
		ok scalar(@vs_calls) >= 1, 'validate_strict invoked during import()';

		Test::Mockingbird::restore_all();
	};
}

done_testing;
