#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Spec;

BEGIN {
	my $here = dirname(File::Spec->rel2abs($0));
	unshift @INC, File::Spec->catdir($here, '..', 'lib');
}

use Pldock;

is(Pldock::parse_dim('1/3', 1920), 640, '1/3 of 1920');
is(Pldock::parse_dim('50%', 800), 400, '50%');
is(Pldock::parse_dim('155', 1080), 155, 'pixels');
ok(!defined Pldock::parse_dim('auto', 1080), 'auto is undef');

my $cfg = Pldock::parse_conf_text(Pldock::default_conf_text(), 'builtin');
is($cfg->{pos}, 'bottom-right', 'default pos');
is($cfg->{width}, '1/3', 'default width spec');
ok($cfg->{height_auto}, 'height auto');
is($cfg->{root}{type}, 'vbox', 'root vbox');
my @tiles = Pldock::flatten_tiles($cfg->{root});
is(scalar @tiles, 4, 'four tiles');
is_deeply([ map { $_->{id} } @tiles ],
	[ qw(wmclock wmapm xload xconsole) ], 'order');
ok(!$tiles[0]{stretch}, 'clock native');
ok($tiles[2]{stretch}, 'xload stretch');
ok($tiles[3]{stretch}, 'console stretch');
is($tiles[3]{min}, 96, 'console min');

my $file = File::Spec->catfile(dirname(File::Spec->rel2abs($0)), '..', 'pldock.conf');
ok(-f $file, 'shipped pldock.conf');
my $from_file = Pldock::load_conf($file);
is($from_file->{pos}, 'bottom-right', 'file pos');
is(scalar Pldock::flatten_tiles($from_file->{root}), 4, 'file four tiles');

my $nested = Pldock::parse_conf_text(<<'C', 't');
dock {
	pos top-left
	width 400
	height 200
	hbox {
		vbox {
			tile a
			tile b stretch
		}
		tile c stretch weight=2 cmd="xload -nolabel" match=xload,XLoad
	}
}
C
is($nested->{pos}, 'top-left', 'nested pos');
is($nested->{width}, '400', 'nested width');
my @n = Pldock::flatten_tiles($nested->{root});
is(scalar @n, 3, 'three tiles in nested');
is_deeply($n[2]{argv}, [ 'xload', '-nolabel' ], 'cmd split');
is_deeply($n[2]{match}, [ 'xload', 'XLoad' ], 'match list');
is($n[2]{weight}, 2, 'weight');

eval { Pldock::parse_conf_text("tile wmclock\n", 'bad') };
like($@, qr/expected 'dock'/, 'must start with dock');

eval { Pldock::parse_conf_text("dock { }\n", 'empty') };
like($@, qr/no tiles/, 'empty dock');

done_testing();
