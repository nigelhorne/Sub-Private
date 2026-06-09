#!/usr/bin/env perl

use strict;
use warnings;
use Module::Build;

Module::Build->new(
	module_name         => 'Sub::Private',
	license             => 'perl',
	dist_author         => 'Nigel Horne <njh@bandsman.co.uk>',
	dist_version_from   => 'lib/Sub/Private.pm',
	configure_requires => { 'Module::Build' => 0.42 },
	build_requires => {
		'Test::Most'      => 0,
		'Test::NoWarnings' => 0,
	}, requires => {
		'Attribute::Handlers'        => 0,
		'B::Hooks::EndOfScope'       => 0,
		'Carp'                       => 0,
		'namespace::clean'           => 0,
		'Params::Get'                => 0,
		'Params::Validate::Strict'   => 0.33,
		'Readonly'                   => 0,
		'Return::Set'                => 0,
		'Scalar::Util'               => 0,
		'Sub::Identify'              => 0,
	},
	add_to_cleanup      => [ 'Sub-Private-*' ],
	meta_merge => {
		resources => {
			repository => 'https://github.com/nigelhorne/Sub-Private',
			bugtracker => 'https://rt.cpan.org/Public/Dist/Display.html?Name=Sub-Private',
		}
	}, test_requires => {
		'Test::DescribeMe'   => 0,
		'Test::Memory::Cycle' => 0,
		'Test::Most'         => 0,
		'Test::Needs'        => 0,
		'Test::NoWarnings'   => 0,
	}
)->create_build_script();
