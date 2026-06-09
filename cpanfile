# Generated from Makefile.PL using makefilepl2cpanfile

requires 'perl', '5.008';

requires 'Attribute::Handlers';
requires 'B::Hooks::EndOfScope';
requires 'Carp';
requires 'Params::Get';
requires 'Params::Validate::Strict', '0.33';
requires 'Readonly';
requires 'Return::Set';
requires 'Scalar::Util';
requires 'Sub::Identify';
requires 'namespace::clean';

on 'test' => sub {
	requires 'IPC::System::Simple';
	requires 'Test::DescribeMe';
	requires 'Test::Memory::Cycle';
	requires 'Test::Most';
	requires 'Test::Needs';
	requires 'Test::NoWarnings';
};

on 'develop' => sub {
	requires 'Devel::Cover';
	requires 'Perl::Critic';
	requires 'Test::Pod';
	requires 'Test::Pod::Coverage';
};
