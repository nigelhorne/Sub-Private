#!/usr/bin/perl
# t/integration.t -- end-to-end integration tests for Sub::Private

use strict;
use warnings;

use Test::Most;
use Test::Needs;
use Readonly;

my $have_returns     = eval { require Test::Returns; Test::Returns->import; 1 };
my $have_mockingbird = eval { require Test::Mockingbird; Test::Mockingbird->import; 1 };

# Set enforce mode globally for this integration test.
BEGIN { $Sub::Private::config{mode} = 'enforce' }

use_ok 'Sub::Private' or BAIL_OUT 'Sub::Private failed to load';

Readonly::Scalar my $SP      => 'Sub::Private';
Readonly::Scalar my $VERSION => '0.04';

my %config = (
	n_instances    => 5,
	helper_result  => 'helper result',
	step1_result   => 'step1',
	alpha_result   => 'alpha_secret',
	beta_result    => 'beta_secret',
);

# -------------------------------------------------------------------
# Fixtures -- all at compile time so wrapping happens at CHECK
# -------------------------------------------------------------------

# ===== Scenario A: basic OO class with private sub =====

{
	package IntFoo;
	use Sub::Private;

	sub new         { bless {}, shift }
	sub _helper     :Private { 'helper result' }
	sub call_helper { (shift)->_helper }
}

{
	package IntFooChild;
	our @ISA = ('IntFoo');
	sub new        { bless {}, shift }
	sub try_helper { (shift)->_helper }
}

{
	package IntVet;
	sub new   { bless {}, shift }
	sub probe { (shift->[0])->_helper }
}

# ===== Scenario B: cross-private calls (private calling private) =====

{
	package IntCross;
	use Sub::Private;

	sub new    { bless {}, shift }
	sub _step1 :Private { 'step1' }
	sub _step2 :Private { my $s = shift; 'step2+' . $s->_step1 }
	sub run    { (shift)->_step2 }
}

# ===== Scenario C: same sub name in two independent packages =====

{
	package IntAlpha;
	use Sub::Private;
	sub new     { bless {}, shift }
	sub _secret :Private { 'alpha_secret' }
	sub reveal  { (shift)->_secret }
}

{
	package IntBeta;
	use Sub::Private;
	sub new     { bless {}, shift }
	sub _secret :Private { 'beta_secret' }
	sub reveal  { (shift)->_secret }
}

{
	package IntThief;
	sub new     { bless {}, shift }
	sub steal_a { IntAlpha->new->_secret }
	sub steal_b { IntBeta->new->_secret  }
}

# ===== Scenario D: mixed attribute + declarative forms =====

{
	package IntMixed;
	use Sub::Private qw(_decl_one);

	sub new        { bless {}, shift }
	sub _decl_one  { 'decl_one' }
	sub _attr_one  :Private { 'attr_one' }
	sub get_d1     { (shift)->_decl_one }
	sub get_a1     { (shift)->_attr_one }
}

{
	package IntMixedStranger;
	sub new    { bless {}, shift }
	sub try_d1 { IntMixed->new->_decl_one }
	sub try_a1 { IntMixed->new->_attr_one }
}

# ===== Scenario E: UNIVERSAL registration (no per-package use needed) =====

{
	package IntNoUse;
	sub new        { bless {}, shift }
	sub _secret    :Private { 'confidential' }
	sub get_secret { (shift)->_secret }
}

{
	package IntNoUseStranger;
	sub new   { bless {}, shift }
	sub probe { IntNoUse->new->_secret }
}


# -------------------------------------------------------------------
# Tests
# -------------------------------------------------------------------

diag "Running $SP integration tests" if $ENV{TEST_VERBOSE};

# ===================================================================
# SECTION 1: Module load and public interface
# ===================================================================

subtest 'module loads and exposes expected public interface' => sub {
	plan tests => 4;

	is $Sub::Private::VERSION, $VERSION, '$VERSION matches expected';
	is $Sub::Private::BYPASS, 0, '$BYPASS default is 0';
	ok exists $Sub::Private::config{harness_bypass}, '%config has harness_bypass key';
	is $Sub::Private::config{harness_bypass}, 1, 'harness_bypass defaults to 1';
};

# ===================================================================
# SECTION 2: Basic OO class -- owner allows, subclass blocks, stranger blocks
# ===================================================================

subtest 'OO class: owner can call its own private sub' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = IntFoo->new->call_helper }
		'IntFoo owner can call _helper';
	is $result, $config{helper_result}, 'correct return value';
};

subtest 'OO class: SUBCLASS is BLOCKED (private = owner only)' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { IntFooChild->new->try_helper }
		qr/_helper\(\) is a private subroutine of IntFoo/,
		'subclass blocked from parent private sub';
};

subtest 'OO class: stranger is blocked' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok {
		my $vet = bless [IntFoo->new], 'IntVet';
		$vet->probe;
	} qr/private subroutine/, 'stranger blocked';
};

# ===================================================================
# SECTION 3: Cross-private calls
# ===================================================================

subtest 'cross-private: private sub can call sibling private sub' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = IntCross->new->run }
		'_step2 (private) can call _step1 (private) in same package';
	is $result, 'step2+step1', 'chained private result correct';
};

# ===================================================================
# SECTION 4: Concurrent instances -- independent enforcement per package
# ===================================================================

subtest 'concurrent instances: each object enforces independently' => sub {
	my $n = $config{n_instances};
	plan tests => $n * 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my @objs = map { IntFoo->new } 1 .. $n;
	for my $i (0 .. $#objs) {
		my $obj = $objs[$i];
		lives_ok { $obj->call_helper } "instance $i: owner call lives";
		throws_ok { IntThief->new->steal_a }
			qr/private subroutine/, "instance $i: thief still blocked";
	}
};

subtest 'two packages with same sub name enforce independently' => sub {
	plan tests => 4;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my ($ra, $rb);
	lives_ok { $ra = IntAlpha->new->reveal } 'IntAlpha owner can call _secret';
	lives_ok { $rb = IntBeta->new->reveal  } 'IntBeta owner can call _secret';
	is $ra, 'alpha_secret', 'IntAlpha::_secret returns correct value';
	is $rb, 'beta_secret',  'IntBeta::_secret returns correct value';
};

subtest 'thief blocked from both independent packages' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { IntThief->new->steal_a }
		qr/_secret\(\) is a private subroutine of IntAlpha/,
		'thief blocked from IntAlpha::_secret';
	throws_ok { IntThief->new->steal_b }
		qr/_secret\(\) is a private subroutine of IntBeta/,
		'thief blocked from IntBeta::_secret';
};

# ===================================================================
# SECTION 5: Mixed attribute + declarative forms
# ===================================================================

subtest 'mixed forms: owner can call both declarative and attribute private subs' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $obj = IntMixed->new;
	lives_ok { $obj->get_d1 } 'declarative _decl_one accessible from owner';
	lives_ok { $obj->get_a1 } 'attribute _attr_one accessible from owner';
};

subtest 'mixed forms: stranger blocked from both' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { IntMixedStranger->new->try_d1 }
		qr/private subroutine/, 'stranger blocked from declarative _decl_one';
	throws_ok { IntMixedStranger->new->try_a1 }
		qr/private subroutine/, 'stranger blocked from attribute _attr_one';
};

# ===================================================================
# SECTION 6: UNIVERSAL registration (no per-package use)
# ===================================================================

subtest 'UNIVERSAL registration: :Private works without per-package use' => sub {
	plan tests => 2;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = IntNoUse->new->get_secret }
		'owner access works without per-package "use Sub::Private"';
	is $result, 'confidential', 'correct return value';
};

subtest 'UNIVERSAL registration: stranger still blocked' => sub {
	plan tests => 1;
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { IntNoUseStranger->new->probe }
		qr/private subroutine/, 'stranger blocked even without per-package use';
};

# ===================================================================
# SECTION 7: Moo integration (skip if Moo not available)
# ===================================================================

subtest 'Moo integration test' => sub {
	test_needs 'Moo';

	{
		package IntMooBase;
		use Moo;
		use Sub::Private qw(_moo_secret);

		sub _moo_secret { 'moo secret' }
		sub get_secret  { (shift)->_moo_secret }
	}

	{
		package IntMooStranger;
		sub new   { bless {}, shift }
		sub probe { IntMooBase->new->_moo_secret }
	}

	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $result;
	lives_ok { $result = IntMooBase->new->get_secret }
		'Moo: owner can call declarative-wrapped private sub';
	is $result, 'moo secret', 'Moo: correct return value';

	throws_ok { IntMooStranger->new->probe }
		qr/private subroutine/, 'Moo: stranger blocked from wrapped sub';
};

# ===================================================================
# SECTION 8: $BYPASS and %config across multiple active objects
# ===================================================================

subtest 'BYPASS=1 allows ALL active objects, restores cleanly' => sub {
	plan tests => 3;
	local $ENV{HARNESS_ACTIVE} = 0;

	{ local $Sub::Private::BYPASS = 1;
	  lives_ok { IntAlpha->new->reveal } 'alpha owner call lives under BYPASS=1';
	  lives_ok { IntBeta->new->reveal  } 'beta owner call lives under BYPASS=1'; }

	{ local $Sub::Private::BYPASS = 0;
	  throws_ok { IntThief->new->steal_a } qr/private subroutine/,
		'thief blocked again after BYPASS scope exits'; }
};

subtest 'import(): return value is the class name' => sub {
	plan tests => $have_returns ? 2 : 1;

	my $result = Sub::Private->import();
	is $result, $SP, 'import() with no args returns "Sub::Private"';
	returns_ok($result, { type => 'string' }, 'return satisfies string schema')
		if $have_returns;
};

# ===================================================================
# SECTION 9: spy verification (if Test::Mockingbird available)
# ===================================================================

if ($have_mockingbird) {
	subtest 'spy: Sub::Private::croak called on unauthorised access' => sub {
		plan tests => 3;
		local $ENV{HARNESS_ACTIVE}  = 0;
		local $Sub::Private::BYPASS = 0;

		my $spy = Test::Mockingbird::spy('Sub::Private::croak');
		eval { IntThief->new->steal_a };

		my @calls = $spy->();
		ok scalar(@calls) == 1, 'croak called exactly once per unauthorised access';

		my $msg = $calls[0][1];
		like $msg, qr/_secret\(\) is a private subroutine of IntAlpha/,
			'croak message contains sub-name and owner';
		like $msg, qr/cannot be called from IntThief/,
			'croak message contains the caller package';

		Test::Mockingbird::restore_all();
	};
}

done_testing;
