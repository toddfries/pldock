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

use Pldock::Plugin::Barrel;
use Pldock::Plugin::Xloadio;
use Pldock;

is(Pldock::Plugin::Barrel::ease(0), 0, 'ease 0');
is(Pldock::Plugin::Barrel::ease(1), 1, 'ease 1');
ok(Pldock::Plugin::Barrel::ease(0.5) > 0.4, 'ease mid');

my $step = Pldock::Plugin::Barrel::step(4);
ok(abs($step - 1.5708) < 0.01, '90 deg for N=4');

# After a full + click, the destination face is in front (phi=0).
my $phi_to = Pldock::Plugin::Barrel::phi(0, 1, 4, 1, 1);
ok(abs($phi_to) < 0.001, 'to-face at front when u=1');
my $phi_from = Pldock::Plugin::Barrel::phi(0, 0, 4, 1, 1);
ok(abs($phi_from + $step) < 0.01, 'from-face rotated off');

my @vis = Pldock::Plugin::Barrel::visible_faces(0, 4, 1, 0);
is($vis[-1]{i}, 0, 'at rest front is from-face');
ok($vis[-1]{cos} > 0.9, 'front cos ~ 1');

is(Pldock::Plugin::Barrel::src_col(0, 40, 80), 0, 'src start');
is(Pldock::Plugin::Barrel::src_col(39, 40, 80), 78, 'src end-ish');

my $p = Pldock::Plugin::Xloadio->new(input => 'load', want_3d => 1);
my @k = $p->face_keys;
is(scalar @k, 4, 'load has 4 faces');
$p->cycle(1);
ok($p->is_spinning, '3d cycle starts a spin');
is($p->{style}, 'line', 'style unchanged until spin ends');
$p->finish_spin;
is($p->{style}, 'bar', 'finish_spin applies next style');

my %cli = Pldock::parse_cli_argv(qw(--3d));
ok($cli{want_3d}, 'cli --3d');

done_testing();
