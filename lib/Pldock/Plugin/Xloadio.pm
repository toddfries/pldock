package Pldock::Plugin::Xloadio;

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

# CTL_HW / HW_DISKSTATS / HW_DISKCOUNT (sys/sysctl.h)
use constant CTL_HW        => 6;
use constant HW_DISKSTATS  => 9;
use constant HW_DISKCOUNT  => 10;
use constant SYS_sysctl    => 202;

sub new {
	my ($class, %opt) = @_;
	my $input = lc($opt{input} || 'disk');
	$input = 'disk' unless $input eq 'disk' || $input eq 'net';
	return bless {
		input   => $input,
		idx     => 0,          # 0 = total
		hist    => [],
		prev    => undef,
		prev_t  => 0,
		targets => [ 'total' ],
		a_name  => $input eq 'net' ? 'recv' : 'read',
		b_name  => $input eq 'net' ? 'send' : 'write',
	}, $class;
}

sub input { $_[0]{input} }

sub current_label {
	my ($self) = @_;
	my $t = $self->{targets}[ $self->{idx} ];
	return $t if defined $t && length $t;
	return 'total';
}

sub cycle {
	my ($self, $dir) = @_;
	$dir = $dir < 0 ? -1 : 1;
	my $n = @{ $self->{targets} };
	return unless $n;
	$self->{idx} = ($self->{idx} + $dir) % $n;
	$self->{hist} = [];
	$self->{prev} = undef;
}

# Click in the left/right 10px strips cycles targets.
sub click {
	my ($self, $x, $y, $w, $h) = @_;
	return 0 unless defined $x && $w;
	if ($x <= 10) {
		$self->cycle(-1);
		return 1;
	}
	if ($x >= $w - 10) {
		$self->cycle(1);
		return 1;
	}
	return 0;
}

sub sample {
	my ($self) = @_;
	my $now = time();
	my ($vals, $names);
	if ($self->{input} eq 'net') {
		($vals, $names) = _net_counters();
	} else {
		($vals, $names) = _disk_counters();
	}
	$self->{targets} = [ 'total', @$names ];
	if ($self->{idx} >= @{ $self->{targets} }) {
		$self->{idx} = 0;
	}
	my $key = $self->current_label;
	my $pair = $vals->{$key} || { a => 0, b => 0 };
	my $dt = $self->{prev_t} ? ($now - $self->{prev_t}) : 0;
	my $rate = { a => 0, b => 0 };
	if ($dt > 0.05 && $self->{prev} && $self->{prev_key} eq $key) {
		$rate->{a} = ($pair->{a} - $self->{prev}{a}) / $dt;
		$rate->{b} = ($pair->{b} - $self->{prev}{b}) / $dt;
		$rate->{a} = 0 if $rate->{a} < 0;
		$rate->{b} = 0 if $rate->{b} < 0;
		push @{ $self->{hist} }, $rate;
		my $maxh = 240;
		shift @{ $self->{hist} } while @{ $self->{hist} } > $maxh;
	}
	$self->{prev}     = $pair;
	$self->{prev_key} = $key;
	$self->{prev_t}   = $now;
	return $rate;
}

# --- disk ---

sub parse_dmesg_softraid {
	my ($text) = @_;
	my %sr;
	return %sr unless defined $text;
	for my $line (split /\n/, $text) {
		if ($line =~ /^(\S+)\s+at\s+\S+.*<OPENBSD,\s*SR/) {
			$sr{$1} = 1;
		}
	}
	return %sr;
}

# $stats = { sd0 => { a => rbytes, b => wbytes }, ... }
# $sr    = { sd6 => 1, ... }
# Returns names in unique set (softraid volumes + disks that are not
# backing those volumes).
sub unique_disk_names {
	my ($stats, $sr) = @_;
	$stats ||= {};
	$sr    ||= {};
	my @all = sort keys %$stats;
	my @sr  = grep { $sr->{$_} } @all;
	unless (@sr) {
		return @all;
	}
	my %member;
	for my $p (@all) {
		next if $sr->{$p};
		for my $s (@sr) {
			if (_counters_match($stats->{$p}, $stats->{$s})) {
				$member{$p} = 1;
				last;
			}
		}
	}
	return grep { $sr->{$_} || !$member{$_} } @all;
}

sub _counters_match {
	my ($p, $s) = @_;
	return 0 unless $p && $s;
	my $pa = $p->{a} || 0;
	my $pb = $p->{b} || 0;
	my $sa = $s->{a} || 0;
	my $sb = $s->{b} || 0;
	return 0 if ($sa + $sb + $pa + $pb) < 1_000_000;
	my $da = abs($pa - $sa);
	my $db = abs($pb - $sb);
	my $ta = $sa > $pa ? $sa : $pa;
	my $tb = $sb > $pb ? $sb : $pb;
	return 0 if $ta && ($da / $ta) > 0.02;
	return 0 if $tb && ($db / $tb) > 0.02;
	return 1;
}

sub read_diskstats {
	my %out;
	my $count = _sysctl_int(CTL_HW(), HW_DISKCOUNT()) || 0;
	my $mib = pack('ii', CTL_HW(), HW_DISKSTATS());
	my $olen = pack('L!', 0);
	return %out unless syscall(SYS_sysctl(), $mib, 2, 0, $olen, 0, 0) == 0;
	my $need = unpack('L!', $olen);
	return %out unless $need && $count;
	my $rec = int($need / $count);
	return %out unless $rec >= 56;
	my $buf = "\0" x $need;
	$olen = pack('L!', $need);
	return %out unless syscall(SYS_sysctl(), $mib, 2, $buf, $olen, 0, 0) == 0;
	my $len = unpack('L!', $olen);
	for (my $i = 0; $i + $rec <= $len; $i += $rec) {
		my $r = substr($buf, $i, $rec);
		my $name = unpack('Z16', $r);
		next unless $name =~ /\S/;
		my @q = unpack('x24 Q5', $r);
		$out{$name} = { a => $q[3] || 0, b => $q[4] || 0 };
	}
	return %out;
}

sub _sysctl_int {
	my ($a, $b) = @_;
	my $mib = pack('ii', $a, $b);
	my $buf = pack('i!', 0);
	my $olen = pack('L!', length $buf);
	return unless syscall(SYS_sysctl(), $mib, 2, $buf, $olen, 0, 0) == 0;
	return unpack('i!', $buf);
}

sub _read_dmesg {
	my $t = '';
	if (open my $fh, '<', '/var/run/dmesg.boot') {
		local $/;
		$t = <$fh> // '';
		close $fh;
	}
	return $t if $t =~ /softraid|SR CRYPTO|SR RAID/;
	if (open my $fh, '-|', 'dmesg') {
		local $/;
		$t = <$fh> // '';
		close $fh;
	}
	return $t;
}

sub _disk_counters {
	my %stats = read_diskstats();
	my %sr    = parse_dmesg_softraid(_read_dmesg());
	my @uniq  = unique_disk_names(\%stats, \%sr);
	my %vals;
	my ($ta, $tb) = (0, 0);
	for my $n (@uniq) {
		my $s = $stats{$n} || { a => 0, b => 0 };
		$vals{$n} = $s;
		$ta += $s->{a};
		$tb += $s->{b};
	}
	$vals{total} = { a => $ta, b => $tb };
	return (\%vals, \@uniq);
}

# --- net ---

sub parse_netstat_link {
	my ($text) = @_;
	my @rows;
	return @rows unless defined $text;
	for my $line (split /\n/, $text) {
		next unless $line =~ /<Link>/;
		my @f = split ' ', $line;
		next unless @f >= 3;
		my $name = $f[0];
		$name =~ s/\*$//;
		next if $name =~ /^(lo\d*|enc\d*|pflog\d*)$/;
		my $ob = pop @f;
		my $ib = pop @f;
		next unless defined $ib && $ib =~ /^\d+$/ && $ob =~ /^\d+$/;
		push @rows, { name => $name, a => 0 + $ib, b => 0 + $ob };
	}
	return @rows;
}

sub _net_counters {
	my $text = '';
	if (open my $fh, '-|', 'netstat', '-ibn') {
		local $/;
		$text = <$fh> // '';
		close $fh;
	}
	my @rows = parse_netstat_link($text);
	my %vals;
	my ($ta, $tb) = (0, 0);
	my @names;
	my %seen;
	for my $r (@rows) {
		next if $seen{ $r->{name} }++;
		$vals{ $r->{name} } = { a => $r->{a}, b => $r->{b} };
		push @names, $r->{name};
		$ta += $r->{a};
		$tb += $r->{b};
	}
	$vals{total} = { a => $ta, b => $tb };
	return (\%vals, \@names);
}

# --- draw ---

sub draw {
	my ($self, $X, $win, $gcs, $w, $h) = @_;
	return unless $X && $win && $w > 0 && $h > 0;
	my $bg = $gcs->{bg} || 0;
	my $fg = $gcs->{fg};
	my $ga = $gcs->{a};
	my $gb = $gcs->{b};
	$X->PolyFillRectangle($win, $bg, [ 0, 0, $w, $h ]) if $bg;
	my $left  = 10;
	my $right = 10;
	my $top   = 12;
	my $gw    = $w - $left - $right;
	my $gh    = $h - $top - 2;
	return if $gw < 4 || $gh < 4;

	my @hist = @{ $self->{hist} || [] };
	my $max = 1;
	for my $p (@hist) {
		$max = $p->{a} if $p->{a} && $p->{a} > $max;
		$max = $p->{b} if $p->{b} && $p->{b} > $max;
	}
	my $n = @hist;
	if ($n && $ga && $gb) {
		my $use = $n < $gw ? $n : $gw;
		my $off = $n - $use;
		for my $i (0 .. $use - 1) {
			my $p = $hist[ $off + $i ];
			my $x = $left + $i;
			my $ha = int($gh * ($p->{a} || 0) / $max);
			my $hb = int($gh * ($p->{b} || 0) / $max);
			$ha = $gh if $ha > $gh;
			$hb = $gh if $hb > $gh;
			$X->PolyLine($win, $ga, 'Origin',
				$x, $top + $gh, $x, $top + $gh - $ha) if $ha > 0;
			$X->PolyLine($win, $gb, 'Origin',
				$x, $top + $gh, $x, $top + $gh - $hb) if $hb > 0;
		}
	}

	if ($fg) {
		$X->PolyLine($win, $fg, 'Origin',
			$left, $top + $gh, $left + $gw, $top + $gh);
		my $kind = $self->{input};
		my $lab  = $self->current_label;
		my $txt  = "$kind $lab";
		$txt = substr($txt, 0, 24) if length $txt > 24;
		eval { $X->ImageText8($win, $fg, $left + 2, $top - 2, $txt) };
		eval { $X->ImageText8($win, $fg, 1, int($h / 2) + 3, '<') };
		eval { $X->ImageText8($win, $fg, $w - 7, int($h / 2) + 3, '>') };
	}
}

1;
