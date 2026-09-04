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

my $cfg = Pldock::parse_conf_text(Pldock::default_conf_text(), 'builtin');
my $geo = Pldock::dock_geometry($cfg, 1920, 1080);
is($geo->{w}, 640, 'width 1/3 of 1920');
ok($geo->{h} >= 57 + 2 + 96, 'height fits row + console min');
is($geo->{x}, 1920 - 640, 'lower right x');
is($geo->{y}, 1080 - $geo->{h}, 'lower right y');
is($geo->{pos}, 'bottom-right', 'pos');

Pldock::layout_tree($cfg->{root}, $geo->{w}, $geo->{h}, $geo->{gap});
my @t = Pldock::flatten_tiles($cfg->{root});
my %by = map { $_->{id} => $_ } @t;

ok($by{wmclock}{y} < $by{xconsole}{y}, 'clock above console');
ok($by{wmapm}{y} < $by{xconsole}{y}, 'apm above console');
ok($by{xload}{y} < $by{xconsole}{y}, 'xload above console');
is($by{wmclock}{x}, 0, 'clock at left of dock');
ok($by{wmapm}{x} > $by{wmclock}{x}, 'apm right of clock');
ok($by{xload}{x} > $by{wmapm}{x}, 'xload right of apm');
is($by{xconsole}{x}, 0, 'console full-width x');
is($by{xconsole}{w}, 640, 'console full dock width');
is($by{xconsole}{h}, $geo->{h} - $by{wmclock}{h} - 2, 'console gets leftover height');
ok($by{xload}{stretch}, 'xload stretches');
ok($by{xload}{w} > $by{wmclock}{w}, 'xload wider than clock');
is($by{wmclock}{w}, 54, 'clock native width');
is($by{wmapm}{w}, 54, 'apm native width');

# skip console
$cfg = Pldock::parse_conf_text(Pldock::default_conf_text(), 'builtin');
$cfg->{root} = Pldock::prune_tree($cfg->{root}, { xconsole => 1 });
my @left = Pldock::flatten_tiles($cfg->{root});
is(scalar @left, 3, 'pruned console');
is($left[0]{id}, 'wmclock', 'still clock');

my @none = ();
Pldock::layout_tree(undef, 0, 0, 2);
ok(1, 'layout_tree undef is a no-op');

done_testing();
