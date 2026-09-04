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

done_testing();
