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

my ($i, $c) = Pldock::parse_wm_class("wmclock\0WMClock\0");
is($i, 'wmclock', 'instance');
is($c, 'WMClock', 'class');

($i, $c) = Pldock::parse_wm_class("xload\0XLoad");
is($i, 'xload', 'xload instance');
is($c, 'XLoad', 'xload class');

($i, $c) = Pldock::parse_wm_class("");
is($i, '', 'empty instance');
is($c, '', 'empty class');

my @slots = Pldock::default_slots();
my %by = map { $_->{id} => $_ } @slots;

ok(Pldock::class_matches_slot('wmclock', 'WMClock', 'wmclock', $by{wmclock}),
	'clock matches instance');
ok(Pldock::class_matches_slot('xload', 'XLoad', 'xload', $by{xload}),
	'load matches class');
ok(Pldock::class_matches_slot('xconsole', 'XConsole', 'xconsole', $by{xconsole}),
	'console matches');
ok(Pldock::class_matches_slot('wmapm', 'wmapm', 'wmapm', $by{wmapm}),
	'apm matches');
ok(Pldock::class_matches_slot(
	'/usr/local/bin/wmapm', '/usr/local/bin/wmapm',
	'/usr/local/bin/wmapm', $by{wmapm}),
	'apm matches full path WM_CLASS');
ok(Pldock::name_matches('/usr/local/bin/wmapm', 'wmapm'),
	'basename match');
ok(!Pldock::class_matches_slot('xterm', 'XTerm', 'xterm', $by{wmclock}),
	'xterm is not clock');

{
	my @s = map { { swallowed => undef } } 1 .. 3;
	is(Pldock::any_unfilled(\@s), 3, 'all unfilled');
	$s[1]{swallowed} = 42;
	is(Pldock::any_unfilled(\@s), 2, 'one filled');
	$_->{swallowed} = 1 for @s;
	is(Pldock::any_unfilled(\@s), 0, 'none unfilled');
	ok(!Pldock::any_unfilled([]), 'empty list');
}

{
	local $ENV{DISPLAY} = '';
	is(Pldock::run(), 1, 'run exits if DISPLAY is empty');
}
{
	delete local $ENV{DISPLAY};
	is(Pldock::run(), 1, 'run exits if DISPLAY is unset');
}

my %cli = Pldock::parse_cli_argv(
	qw(-override -top -height 80 -no-console -gap 0 -c /tmp/x.conf -screen HDMI-1 -spawn -v)
);
is($cli{pos}, 'top-right', 'cli -top');
ok($cli{override}, 'cli -override');
is($cli{height}, 80, 'cli -height');
ok($cli{skip}{xconsole}, 'cli -no-console');
is($cli{gap}, 0, 'cli -gap');
is($cli{conf}, '/tmp/x.conf', 'cli -c');
is($cli{screen}, 'HDMI-1', 'cli -screen');
ok($cli{spawn}, 'cli -spawn');
ok($cli{verbose}, 'cli -v');

{
	my %d = Pldock::parse_cli_argv(qw(-d));
	ok($d{debug}, 'cli -d');
}

done_testing();
