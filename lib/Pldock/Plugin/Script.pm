package Pldock::Plugin::Script;

# Copyright (c) 2026 Todd T. Fries <todd@fries.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use Time::HiRes qw(time);

sub new {
	my ($class, %opt) = @_;
	my $cmd = $opt{cmd};
	$cmd = '' unless defined $cmd;
	my $refresh = $opt{refresh} || 300;
	$refresh = 1 if $refresh < 1;
	return bless {
		cmd      => $cmd,
		refresh  => $refresh,
		text     => '',
		next     => 0,
	}, $class;
}

sub click { 0 }

sub sample {
	my ($self) = @_;
	my $now = time();
	return $self->{text} if $self->{next} && $now < $self->{next};
	$self->{next} = $now + $self->{refresh};
	$self->{text} = _run($self->{cmd});
	return $self->{text};
}

sub _run {
	my ($cmd) = @_;
	return '' unless defined $cmd && length $cmd;
	my $out = '';
	if (open my $fh, '-|', '/bin/sh', '-c', $cmd) {
		local $/;
		$out = <$fh> // '';
		close $fh;
	}
	$out =~ s/\r//g;
	$out =~ s/\s+\z//;
	return $out;
}

sub draw {
	my ($self, $X, $win, $gcs, $w, $h) = @_;
	return unless $X && $win && $w > 0 && $h > 0;
	my $bg = $gcs->{bg};
	my $fg = $gcs->{fg};
	$X->PolyFillRectangle($win, $bg, [ 0, 0, $w, $h ]) if $bg;
	return unless $fg;
	my $text = $self->{text} // '';
	my @lines = split /\n/, $text;
	@lines = ('') unless @lines;
	my $lh = 12;
	my $maxl = int(($h - 4) / $lh);
	$maxl = 1 if $maxl < 1;
	splice @lines, $maxl if @lines > $maxl;
	my $y = 12;
	my $cols = int(($w - 6) / 6);
	$cols = 8 if $cols < 8;
	for my $line (@lines) {
		$line = substr($line, 0, $cols) if length $line > $cols;
		eval { $X->ImageText8($win, $fg, 4, $y, $line) };
		$y += $lh;
		last if $y > $h - 2;
	}
}

1;
