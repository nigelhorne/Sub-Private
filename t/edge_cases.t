use strict;
use warnings;
use Test::Most;

# Edge cases for enforce mode.  Namespace mode edge cases are in t/basic.t.

# Must be set via BEGIN so attribute handlers fire in enforce mode at CHECK.
BEGIN { $Sub::Private::config{mode} = 'enforce' }

use Sub::Private;

local $ENV{HARNESS_ACTIVE}  = 0;
local $Sub::Private::BYPASS = 0;

# ---- Private sub returning false values: they must propagate intact ----

{
	package EdgeFalse;
	use Sub::Private;
	sub new         { bless {}, shift }
	sub _undef      :Private { return undef }
	sub _zero       :Private { return 0 }
	sub _empty      :Private { return q{} }
	sub get_undef   { (shift)->_undef }
	sub get_zero    { (shift)->_zero }
	sub get_empty   { (shift)->_empty }
}

{
	local $ENV{HARNESS_ACTIVE}     = 0;
	local $Sub::Private::BYPASS    = 0;

	ok !defined( EdgeFalse->new->get_undef ), 'edge: private sub returning undef: propagates';
	is( EdgeFalse->new->get_zero,  0,   'edge: private sub returning 0: propagates' );
	is( EdgeFalse->new->get_empty, q{}, 'edge: private sub returning "": propagates' );
}

# ---- goto &$code forwards positional args correctly ----

{
	package EdgeArgs;
	use Sub::Private;
	sub new  { bless {}, shift }
	sub _sum :Private { my (undef, $a, $b) = @_; $a + $b }
	sub run  { my $s = shift; $s->_sum(@_) }
}

{
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	is( EdgeArgs->new->run(10, 20), 30,
		'edge: goto &$code forwards positional args correctly (10+20=30)' );
}

# ---- Private sub that die()s: exception propagates unmodified ----

{
	package EdgeDie;
	use Sub::Private;
	sub new    { bless {}, shift }
	sub _boom  :Private { die "kaboom\n" }
	sub invoke { (shift)->_boom }
}

{
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	throws_ok { EdgeDie->new->invoke }
		qr/kaboom/,
		'edge: exception from private sub propagates unmodified';
}

# ---- can() in enforce mode returns wrapper CODE ref ----

{
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	my $code = EdgeFalse->can('_undef');
	ok defined($code), 'enforce mode: can() returns defined value for :Private sub';

	# The wrapper returned by can() still blocks unrelated callers
	throws_ok {
		package EdgeCanProber;
		$code->(EdgeFalse->new);
	} qr/private subroutine/,
		'enforce mode: wrapper obtained via can() blocks unrelated caller';
}

# ---- Attribute form and declarative form produce identical behaviour ----

{
	package EdgeAttrPkg;
	use Sub::Private;
	sub new  { bless {}, shift }
	sub _sec :Private { 'attr-sec' }
	sub pub  { (shift)->_sec }
}

{
	package EdgeDeclPkg;
	use Sub::Private qw(_sec);
	sub new  { bless {}, shift }
	sub _sec { 'decl-sec' }
	sub pub  { (shift)->_sec }
}

{
	package EdgeOutsider;
	sub probe_attr { EdgeAttrPkg->new->_sec }
	sub probe_decl { EdgeDeclPkg->new->_sec }
}

{
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	lives_ok { EdgeAttrPkg->new->pub }   'attr form: owner allowed';
	lives_ok { EdgeDeclPkg->new->pub }   'decl form: owner allowed';
	throws_ok { EdgeOutsider::probe_attr() } qr/private subroutine/, 'attr form: outsider blocked';
	throws_ok { EdgeOutsider::probe_decl() } qr/private subroutine/, 'decl form: outsider blocked';
}

# ---- Two independently wrapped subs enforce independently ----

{
	package EdgeTwin;
	use Sub::Private;
	sub new  { bless {}, shift }
	sub _p   :Private { 'p' }
	sub _q   :Private { 'q' }
	sub get_p { (shift)->_p }
	sub get_q { (shift)->_q }
}

{
	local $ENV{HARNESS_ACTIVE}  = 0;
	local $Sub::Private::BYPASS = 0;

	lives_ok { EdgeTwin->new->get_p } 'independent: owner can call _p';
	lives_ok { EdgeTwin->new->get_q } 'independent: owner can call _q';

	throws_ok { EdgeTwin::_p(EdgeTwin->new) } qr/private subroutine/,
		'independent: _p blocked from outside';
	throws_ok { EdgeTwin::_q(EdgeTwin->new) } qr/private subroutine/,
		'independent: _q blocked from outside independently';
}

done_testing;
