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

use Cwd;
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
ok($from_file->{root}, 'shipped conf parses');
ok(Pldock::flatten_tiles($from_file->{root}) > 0, 'shipped conf has tiles');

{
	my $scr = Pldock::parse_conf_text(<<'C', 'script');
dock {
	hbox {
		script "date" freq=300 stretch
		plugin xloadio input=net stretch
	}
}
C
	my @s = Pldock::flatten_tiles($scr->{root});
	is($s[0]{type}, 'script', 'script type');
	is($s[0]{cmd}, 'date', 'script cmd');
	is($s[0]{freq}, 300, 'script freq');
	my $old = Pldock::parse_conf_text(<<'C', 'refresh-alias');
dock { hbox { script "date" refresh=60 stretch } }
C
	my ($os) = Pldock::flatten_tiles($old->{root});
	is($os->{freq}, 60, 'refresh aliases to freq');
	ok($s[0]{stretch}, 'script stretch');
}

{
	require File::Temp;
	my $home = File::Temp::tempdir(CLEANUP => 1);
	my $cwd  = File::Temp::tempdir(CLEANUP => 1);
	open my $fh, '>', "$cwd/pldock.conf" or die $!;
	print $fh "dock { tile wmclock }\n";
	close $fh;
	my $old = Cwd::cwd();
	chdir $cwd or die $!;
	local $ENV{HOME} = $home;
	delete local $ENV{PLDOCK_CONF};
	ok(!Pldock::find_conf_path(), 'cwd pldock.conf is not used');
	require File::Path;
	File::Path::mkpath("$home/.config/pldock");
	open $fh, '>', "$home/.config/pldock/pldock.conf" or die $!;
	print $fh "dock { tile wmapm }\n";
	close $fh;
	like(Pldock::find_conf_path(), qr/\.config\/pldock\/pldock\.conf$/,
		'only ~/.config/pldock/pldock.conf');
	chdir $old;
}

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
