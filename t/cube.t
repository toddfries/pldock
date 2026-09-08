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

use Pldock::Plugin::Cube;

is(Pldock::Plugin::Cube::pot(50), 64, 'pot 50');
is(Pldock::Plugin::Cube::pot(128), 128, 'pot 128');

my $row = pack('C3', 1, 2, 3) . pack('C3', 4, 5, 6);
my $img = $row . pack('C3', 7, 8, 9) . pack('C3', 10, 11, 12);
my $fl  = Pldock::Plugin::Cube::yflip_rgb($img, 2, 2);
is(substr($fl, 0, 3), pack('C3', 7, 8, 9), 'yflip first row was last');

# BGRA pixel → RGB
my $bgra = pack('C4', 9, 10, 11, 0);    # B,G,R,A
my $rgb  = Pldock::Plugin::Cube::ximage_to_rgb(1, 1, $bgra, 4);
is($rgb, pack('C3', 11, 10, 9), 'bgra to rgb');

my $back = Pldock::Plugin::Cube::rgb_to_bgra($rgb, 1, 1);
is($back, $bgra, 'rgb to bgra roundtrip');

ok(Pldock::Plugin::Cube::available(), 'SDL::OpenGL present on this box');

done_testing();
