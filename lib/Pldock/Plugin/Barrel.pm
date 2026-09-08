package Pldock::Plugin::Barrel;

# Software drum for --3d: N faces around Y, 3dTest-style |cos| squash.
# Copyright (c) 2026 Todd T. Fries <todd@fries.net>

use strict;
use warnings;
use constant PI => 3.14159265358979323846;

sub ease {
	my ($u) = @_;
	$u = 0 if $u < 0;
	$u = 1 if $u > 1;
	return $u * $u * (3 - 2 * $u);
}

sub step {
	my ($n) = @_;
	$n = 2 if !$n || $n < 2;
	return 2 * PI() / $n;
}

# theta(0)=0; theta(1)= -dir * 2π/N  (next face in front)
sub theta {
	my ($dir, $n, $u) = @_;
	return -$dir * step($n) * ease($u);
}

sub phi {
	my ($from, $i, $n, $dir, $u) = @_;
	return theta($dir, $n, $u) + ($i - $from) * step($n);
}

# Faces with cos>eps, back to front (increasing cos).
sub visible_faces {
	my ($from, $n, $dir, $u, $eps) = @_;
	$eps = 0.08 unless defined $eps;
	my @out;
	for my $i (0 .. $n - 1) {
		my $p = phi($from, $i, $n, $dir, $u);
		my $c = cos($p);
		next if $c <= $eps;
		push @out, {
			i    => $i,
			phi  => $p,
			cos  => $c,
			sin  => sin($p),
		};
	}
	return sort { $a->{cos} <=> $b->{cos} } @out;
}

# Dest strip: center and width in window pixels.
sub strip {
	my ($face, $w) = @_;
	$w ||= 1;
	my $dw = int($w * $face->{cos} + 0.5);
	$dw = 1 if $dw < 1;
	my $cx = $w / 2;
	my $x0 = int($cx + ($w / 2) * $face->{sin} - $dw / 2);
	return ($x0, $dw);
}

sub src_col {
	my ($dx, $dw, $sw) = @_;
	return 0 if $dw < 1 || $sw < 1;
	my $sx = int($dx * $sw / $dw);
	$sx = $sw - 1 if $sx >= $sw;
	$sx = 0 if $sx < 0;
	return $sx;
}

1;
