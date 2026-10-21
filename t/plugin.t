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
use Pldock::Plugin;
use Pldock::Plugin::Xloadio;

is(Pldock::Plugin::class_for('xloadio'), 'Pldock::Plugin::Xloadio', 'class_for');

my $cfg = Pldock::parse_conf_text(<<'C', 'plug');
dock {
	pos bottom-right
	width 400
	hbox {
		tile wmclock
		plugin xloadio input=disk stretch
		plugin xloadio input=net stretch
	}
}
C
my @s = Pldock::flatten_tiles($cfg->{root});
is(scalar @s, 3, 'clock + two plugins');
is($s[1]{type}, 'plugin', 'plugin type');
is($s[1]{plugin}, 'xloadio', 'plugin name');
is($s[1]{input}, 'disk', 'disk input');
is($s[1]{id}, 'xloadio-disk', 'disk id');
ok($s[1]{stretch}, 'plugin stretch');
is($s[2]{input}, 'net', 'net input');
is($s[2]{id}, 'xloadio-net', 'net id');

my $dmesg = <<'D';
sd0 at scsibus1 targ 0 lun 0: <ATA, ST500, 0005>
sd6 at scsibus8 targ 1 lun 0: <OPENBSD, SR CRYPTO, 006>
sd1 at scsibus2 targ 1 lun 0: <Seagate, Go, 102F>
sd8 at scsibus8 targ 3 lun 0: <OPENBSD, SR CRYPTO, 006>
D
my %sr = Pldock::Plugin::Xloadio::parse_dmesg_softraid($dmesg);
ok($sr{sd6}, 'sd6 softraid');
ok($sr{sd8}, 'sd8 softraid');
ok(!$sr{sd0}, 'sd0 not softraid');

my $stats = {
	sd0 => { a => 100_000_000, b => 200_000_000 },
	sd6 => { a => 100_100_000, b => 200_050_000 },
	sd1 => { a => 50_000_000,  b => 60_000_000 },
	sd8 => { a => 50_100_000,  b => 60_200_000 },
	sd2 => { a => 10,          b => 0 },
};
my @u = Pldock::Plugin::Xloadio::unique_disk_names($stats, \%sr);
is_deeply([ sort @u ], [ qw(sd2 sd6 sd8) ], 'unique skips softraid members');

my $net = <<'N';
Name    Mtu   Network     Address               Ibytes     Obytes
lo0     32768 <Link>                        1000 1000
re0     1500  <Link>      98:40:bb:0b:4f:d0 200 50
iwm0    1500  <Link>      d0:7e:35:12:9a:03 10 1
enc0*   0     <Link>                                 0          0
pflog0  33136 <Link>                                 0          3
N
my @n = Pldock::Plugin::Xloadio::parse_netstat_link($net);
is(scalar @n, 2, 'skip lo/enc/pflog');
is($n[0]{name}, 're0', 're0');
is($n[0]{a}, 200, 'recv');
is($n[0]{b}, 50, 'send');
is($n[1]{name}, 'iwm0', 'iwm0');

my $p = Pldock::Plugin::Xloadio->new(input => 'disk');
is($p->current_label, 'total', 'start on total');
$p->{targets} = [ qw(total sd6 sd8) ];
$p->cycle(1);
is($p->current_label, 'sd6', 'cycle next');
$p->cycle(1);
is($p->current_label, 'sd8', 'cycle next');
$p->cycle(1);
is($p->current_label, 'total', 'wrap');
$p->cycle(-1);
is($p->current_label, 'sd8', 'cycle prev wrap');
ok($p->click(2, 10, 100, 40), 'left <');
ok($p->click(95, 10, 100, 40), 'right >');
ok(!$p->click(50, 10, 100, 40), 'middle no cycle');

is(Pldock::Plugin::Xloadio::parse_color('#66cc66'), 0x66cc66, 'hash color');
is(Pldock::Plugin::Xloadio::parse_color('0xCCCC44'), 0xCCCC44, '0x color');
is(Pldock::Plugin::Xloadio::parse_color('green'), 0x66CC66, 'named color');

my $loadcfg = Pldock::parse_conf_text(<<'C', 'load');
dock {
	hbox {
		plugin xloadio input=load style=bar color0=green color1=yellow color2=red stretch
		plugin xloadio input=mem style=stack stretch
		plugin xloadio input=disk style=bar colors=green,yellow stretch
	}
}
C
my @lp = Pldock::flatten_tiles($loadcfg->{root});
is($lp[0]{input}, 'load', 'load input');
is($lp[0]{style}, 'bar', 'load style bar');
is($lp[0]{color0}, 'green', 'color0');
is($lp[1]{input}, 'mem', 'mem input');
is($lp[1]{style}, 'stack', 'mem stack');
is($lp[2]{style}, 'bar', 'disk bar');
is($lp[2]{colors}, 'green,yellow', 'colors list');

my $ld = Pldock::Plugin::Xloadio->new(input => 'load', style => 'line');
is($ld->{style}, 'line', 'load default line');
$ld->cycle(1);
is($ld->{style}, 'bar', 'load cycle to bar');
$ld->cycle(1);
is($ld->{style}, 'stack', 'load cycle to stack');
$ld->cycle(1);
is($ld->{style}, 'lanes', 'load cycle to lanes');

my $mem = Pldock::Plugin::Xloadio->new(input => 'mem');
is($mem->{style}, 'stack', 'mem default stack');
is($mem->{view}, 'both', 'mem view both');
$mem->cycle(1);
is($mem->{view}, 'ram', 'mem cycle ram');

# synthetic loadavg: 1.0 2.0 3.0 with fscale 2048
my $lbuf = pack('I3 x4 q', 2048, 4096, 6144, 2048);
my $lv = Pldock::Plugin::Xloadio::parse_loadavg_buf($lbuf);
ok(abs($lv->[0] - 1.0) < 0.01, 'load 1min');
ok(abs($lv->[1] - 2.0) < 0.01, 'load 5min');
ok(abs($lv->[2] - 3.0) < 0.01, 'load 15min');

# uvmexp: enough ints for wired/swap
my @uv = (0) x 30;
$uv[0] = 4096;
$uv[3] = 1000;
$uv[4] = 400;
$uv[5] = 200;
$uv[6] = 100;
$uv[8] = 50;
$uv[13] = 30;
$uv[14] = 20;
$uv[26] = 500;
$uv[27] = 100;
my $ub = pack('i*', @uv);
my $mv = Pldock::Plugin::Xloadio::parse_uvmexp_buf($ub);
is($mv->{free}, 400, 'mem free');
is($mv->{active}, 200, 'mem active');
is($mv->{wired}, 50, 'mem wired');
is($mv->{cache}, 150, 'mem cache inactive+vnode+vtext');
is($mv->{swapu}, 100, 'swap used');
is($mv->{swapf}, 400, 'swap free');

$mem->{view} = 'swap';
is_deeply($mem->_hist_vec({
	wired => 1, active => 2, cache => 3, free => 4, swapu => 10, swapf => 20,
}), [ 10, 20 ], 'swap view is swap only');
$mem->{view} = 'ram';
is_deeply($mem->_hist_vec({
	wired => 1, active => 2, cache => 3, free => 4, swapu => 10, swapf => 20,
}), [ 1, 2, 3, 4 ], 'ram view is ram only');

is(Pldock::Plugin::Xloadio::nice_ceil(1.0), 1, 'scale 1.0');
is(Pldock::Plugin::Xloadio::nice_ceil(0.5), 0.5, 'scale 0.5');
ok(abs(Pldock::Plugin::Xloadio::nice_ceil(0.51) - 0.6) < 1e-9, 'scale 0.51 -> 0.6');
ok(abs(Pldock::Plugin::Xloadio::nice_ceil(1.01) - 1.2) < 1e-9, 'scale 1.01 -> 1.2 not 2');
ok(abs(Pldock::Plugin::Xloadio::nice_ceil(2.01) - 2.5) < 1e-9, 'scale 2.01 -> 2.5 not 5');
ok(abs(Pldock::Plugin::Xloadio::nice_ceil(2.6) - 3) < 1e-9, 'scale 2.6 -> 3 not 5');

is(Pldock::Plugin::Xloadio::default_freq('load', 'lanes'), 0.25, 'lanes freq 1/4s');
is(Pldock::Plugin::Xloadio::default_freq('disk', 'line'), 1, 'disk freq 1s');

my $dk = Pldock::Plugin::Xloadio->new(input => 'disk');
$dk->{targets} = [ qw(total sd6) ];
$dk->{cycle_list} = [ qw(total sd6) ];
$dk->{hist_by}{total} = [ [ 1, 2 ], [ 3, 4 ] ];
$dk->cycle(1);
is($dk->_hist_key, 'sd6', 'flipped to member');
$dk->cycle(-1);
is($dk->_hist_key, 'total', 'back to total');
is(scalar @{ $dk->_hist }, 2, 'history kept');

ok(!Pldock::Plugin::Xloadio::sample_nonzero([ 0, 0 ]), 'zero sample');
ok(Pldock::Plugin::Xloadio::sample_nonzero([ 0, 3 ]), 'nonzero sample');
ok(!Pldock::Plugin::Xloadio::hist_is_active([ [0,0], [0,0], [1,0] ], 10),
	'one blip is idle');
ok(Pldock::Plugin::Xloadio::hist_is_active([ [0,0], [1,0], [2,0] ], 10),
	'two blips are live');
{
	my $io = Pldock::Plugin::Xloadio->new(input => 'disk');
	$io->{last_gw} = 80;
	$io->{hist_by}{enc0} = [ ([ 0, 0 ]) x 20 ];
	$io->{hist_by}{re0}  = [ [ 0, 0 ], [ 5, 1 ], [ 3, 0 ], ([ 0, 0 ]) x 5 ];
	my @live = $io->live_cycle_list([ qw(enc0 re0 lo0) ]);
	is_deeply(\@live, [ qw(total re0) ], 'idle ifaces omitted from cycle');
}

my $fcfg = Pldock::parse_conf_text(<<'C', 'freq');
dock {
	hbox {
		plugin xloadio input=load style=lanes freq=0.25 stretch
	}
}
C
my ($fl) = Pldock::flatten_tiles($fcfg->{root});
is($fl->{style}, 'lanes', 'parse lanes');
is($fl->{freq} + 0, 0.25, 'parse freq 0.25');

done_testing();
