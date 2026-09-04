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

my $sample = <<'XR';
Screen 0: minimum 320 x 200, current 3840 x 1080, maximum 16384 x 16384
eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 309mm x 173mm
   1920x1080     60.05*+
HDMI-1 connected 1920x1080+1920+0 (normal left inverted right x axis y axis) 477mm x 268mm
   1920x1080     60.00*+
HDMI-2 disconnected (normal left inverted right x axis y axis)
XR

my @o = Pldock::parse_xrandr($sample);
is(scalar @o, 2, 'two connected outputs');
is($o[0]{name}, 'eDP-1', 'laptop');
ok($o[0]{primary}, 'eDP-1 primary');
is($o[0]{w}, 1920, 'eDP width');
is($o[0]{x}, 0, 'eDP x');
is($o[1]{name}, 'HDMI-1', 'hdmi');
ok(!$o[1]{primary}, 'hdmi not primary');
is($o[1]{x}, 1920, 'hdmi origin x');
is($o[1]{y}, 0, 'hdmi origin y');

my $p = Pldock::pick_output(\@o, 'primary');
is($p->{name}, 'eDP-1', 'pick primary');
is(Pldock::pick_output(\@o, undef)->{name}, 'eDP-1', 'undef is primary');
is(Pldock::pick_output(\@o, 'HDMI-1')->{name}, 'HDMI-1', 'by name');
is(Pldock::pick_output(\@o, 'hdmi-1')->{name}, 'HDMI-1', 'name case');
is(Pldock::pick_output(\@o, 'right')->{name}, 'HDMI-1', 'right');
is(Pldock::pick_output(\@o, 'left')->{name}, 'eDP-1', 'left');
is(Pldock::pick_output(\@o, '0')->{name}, 'eDP-1', 'index 0');
is(Pldock::pick_output(\@o, '1')->{name}, 'HDMI-1', 'index 1');
ok(!Pldock::pick_output(\@o, 'DP-9'), 'missing name');
ok(!Pldock::pick_output([]), 'empty list');

my $cfg = Pldock::parse_conf_text(Pldock::default_conf_text(), 'builtin');
is($cfg->{screen}, 'primary', 'conf screen primary');
my $geo = Pldock::dock_geometry($cfg, $o[1]);
is($geo->{w}, 640, '1/3 of HDMI width');
is($geo->{x}, 1920 + 1920 - 640, 'lower right of HDMI, global x');
ok($geo->{y} > 0, 'above bottom of HDMI');
is($geo->{y} + $geo->{h}, 1080, 'sits on HDMI bottom');

done_testing();
