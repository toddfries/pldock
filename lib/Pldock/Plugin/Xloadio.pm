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

# CTL_HW / HW_DISKSTATS / HW_DISKCOUNT / HW_NCPU (sys/sysctl.h)
# CTL_VM / VM_LOADAVG / VM_UVMEXP (uvm/uvmexp.h)
use constant CTL_HW        => 6;
use constant HW_DISKSTATS  => 9;
use constant HW_DISKCOUNT  => 10;
use constant HW_NCPU       => 3;
use constant CTL_VM        => 2;
use constant VM_LOADAVG    => 2;
use constant VM_UVMEXP     => 4;
use constant SYS_sysctl    => 202;

my %COLOR_NAME = (
	green  => 0x66CC66,
	yellow => 0xCCCC44,
	red    => 0xCC6666,
	cyan   => 0x66CCCC,
	orange => 0xCC8844,
	gray   => 0x888888,
	grey   => 0x888888,
	blue   => 0x4488CC,
	magenta=> 0xCC66CC,
	white  => 0xFFFFFF,
	black  => 0x000000,
);

sub parse_color {
	my ($s) = @_;
	return unless defined $s && length $s;
	$s =~ s/^#//;
	$s =~ s/^0x//i;
	return hex($s) if $s =~ /^[0-9a-fA-F]{6}$/;
	return $COLOR_NAME{ lc $s };
}

sub default_colors {
	my ($input) = @_;
	$input = '' unless defined $input;
	return (0xCC8844, 0x66CC66, 0x66CCCC, 0x888888, 0xCC6666, 0x4488CC)
	  if $input eq 'mem';
	return (0x66CC66, 0xCCCC44, 0xCC6666) if $input eq 'load';
	return (0x66CC66, 0xCCCC44);
}

sub new {
	my ($class, %opt) = @_;
	my $input = lc($opt{input} || 'disk');
	$input = 'disk' unless $input =~ /^(disk|net|load|mem)$/;
	my $style = lc($opt{style} || '');
	$style = $input eq 'mem' ? 'stack' : 'line' unless $style =~ /^(line|bar|stack)$/;
	my @colors = @{ $opt{colors} || [] };
	@colors = map { parse_color($_) } @colors;
	@colors = grep { defined } @colors;
	my $names;
	$names = [ qw(read write) ] if $input eq 'disk';
	$names = [ qw(recv send) ] if $input eq 'net';
	$names = [ qw(1 5 15) ] if $input eq 'load';
	$names = [ qw(wired active cache free swapu swapf) ] if $input eq 'mem';
	return bless {
		input   => $input,
		style   => $style,
		idx     => 0,
		hist    => [],
		prev    => undef,
		prev_t  => 0,
		targets => [ 'total' ],
		series  => $names,
		colors  => \@colors,
		ncpu    => _sysctl_int(CTL_HW(), HW_NCPU()) || 1,
		view    => 'both',
	}, $class;
}

sub input { $_[0]{input} }

sub current_label {
	my ($self) = @_;
	if ($self->{input} eq 'load') {
		return $self->{style};
	}
	if ($self->{input} eq 'mem') {
		return $self->{view} || 'both';
	}
	my $t = $self->{targets}[ $self->{idx} ];
	return $t if defined $t && length $t;
	return 'total';
}

sub cycle {
	my ($self, $dir) = @_;
	$dir = $dir < 0 ? -1 : 1;
	if ($self->{input} eq 'load') {
		my @st = qw(line bar stack);
		my $i = 0;
		for my $k (0 .. $#st) { $i = $k if $st[$k] eq $self->{style} }
		$self->{style} = $st[ ($i + $dir) % @st ];
		return;
	}
	if ($self->{input} eq 'mem') {
		my @v = qw(both ram swap);
		my $i = 0;
		for my $k (0 .. $#v) { $i = $k if $v[$k] eq ($self->{view} || 'both') }
		$self->{view} = $v[ ($i + $dir) % @v ];
		return;
	}
	my $n = @{ $self->{targets} };
	return unless $n;
	$self->{idx} = ($self->{idx} + $dir) % $n;
	$self->{hist} = [];
	$self->{prev} = undef;
}

# Left/right 14px strips cycle targets (disk/net), style (load), or view (mem).
sub click {
	my ($self, $x, $y, $w, $h) = @_;
	return 0 unless defined $x && $w;
	my $hit = 14;
	$hit = int($w / 4) if $w < 56;
	$hit = 8 if $hit < 8;
	if ($x <= $hit) {
		$self->cycle(-1);
		return 1;
	}
	if ($x >= $w - $hit) {
		$self->cycle(1);
		return 1;
	}
	return 0;
}

sub sample {
	my ($self) = @_;
	my $now = time();
	if ($self->{input} eq 'load') {
		my $v = _load_values();
		push @{ $self->{hist} }, $v;
		shift @{ $self->{hist} } while @{ $self->{hist} } > 240;
		$self->{cur} = $v;
		return $v;
	}
	if ($self->{input} eq 'mem') {
		my $v = _mem_values();
		push @{ $self->{hist} }, $v;
		shift @{ $self->{hist} } while @{ $self->{hist} } > 240;
		$self->{cur} = $v;
		return $v;
	}
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
	my $rate = [ 0, 0 ];
	if ($dt > 0.05 && $self->{prev} && ($self->{prev_key} || '') eq $key) {
		$rate->[0] = ($pair->{a} - $self->{prev}{a}) / $dt;
		$rate->[1] = ($pair->{b} - $self->{prev}{b}) / $dt;
		$rate->[0] = 0 if $rate->[0] < 0;
		$rate->[1] = 0 if $rate->[1] < 0;
		push @{ $self->{hist} }, $rate;
		shift @{ $self->{hist} } while @{ $self->{hist} } > 240;
	}
	$self->{prev}     = $pair;
	$self->{prev_key} = $key;
	$self->{prev_t}   = $now;
	$self->{cur}      = $rate;
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

# --- load ---

sub parse_loadavg_buf {
	my ($buf) = @_;
	return [ 0, 0, 0 ] unless defined $buf && length($buf) >= 20;
	my ($a, $b, $c, $fscale) = unpack('I3 x4 q', $buf);
	$fscale ||= 2048;
	return [ $a / $fscale, $b / $fscale, $c / $fscale ];
}

sub _load_values {
	my $mib = pack('ii', CTL_VM(), VM_LOADAVG());
	my $olen = pack('L!', 0);
	return [ 0, 0, 0 ] unless syscall(SYS_sysctl(), $mib, 2, 0, $olen, 0, 0) == 0;
	my $need = unpack('L!', $olen);
	return [ 0, 0, 0 ] unless $need;
	my $buf = "\0" x $need;
	$olen = pack('L!', $need);
	return [ 0, 0, 0 ] unless syscall(SYS_sysctl(), $mib, 2, $buf, $olen, 0, 0) == 0;
	return parse_loadavg_buf($buf);
}

# --- memory ---
# uvmexp ints: pagesize@0 npages@12 free@16 active@20 inactive@24
# wired@32 vnodepages@52 vtextpages@56 swpages@104 swpginuse@108

sub parse_uvmexp_buf {
	my ($buf) = @_;
	return {} unless defined $buf && length($buf) >= 112;
	my @i = unpack('i*', $buf);
	my $ps = $i[0] || 4096;
	my $np = $i[3] || 0;
	my $free = $i[4] || 0;
	my $active = $i[5] || 0;
	my $inactive = $i[6] || 0;
	my $wired = $i[8] || 0;
	my $vnode = $i[13] || 0;
	my $vtext = $i[14] || 0;
	my $swpages = $i[26] || 0;
	my $swuse = $i[27] || 0;
	my $cache = $inactive + $vnode + $vtext;
	$cache = 0 if $cache < 0;
	my $used = $wired + $active + $cache + $free;
	my $other = $np > $used ? $np - $used : 0;
	my $swfree = $swpages > $swuse ? $swpages - $swuse : 0;
	return {
		pagesize => $ps,
		npages   => $np,
		wired    => $wired,
		active   => $active,
		cache    => $cache,
		free     => $free,
		other    => $other,
		swapu    => $swuse,
		swapf    => $swfree,
		swpages  => $swpages,
	};
}

sub _mem_values {
	my $mib = pack('ii', CTL_VM(), VM_UVMEXP());
	my $olen = pack('L!', 0);
	return {} unless syscall(SYS_sysctl(), $mib, 2, 0, $olen, 0, 0) == 0;
	my $need = unpack('L!', $olen);
	return {} unless $need;
	my $buf = "\0" x $need;
	$olen = pack('L!', $need);
	return {} unless syscall(SYS_sysctl(), $mib, 2, $buf, $olen, 0, 0) == 0;
	return parse_uvmexp_buf($buf);
}

sub _mem_series {
	my ($self, $m) = @_;
	$m ||= {};
	my $view = $self->{view} || 'both';
	if ($view eq 'swap') {
		return [ $m->{swapu} || 0, $m->{swapf} || 0 ], [ qw(swapu swapf) ];
	}
	if ($view eq 'ram') {
		return [
			$m->{wired} || 0, $m->{active} || 0, $m->{cache} || 0,
			$m->{free} || 0, $m->{other} || 0,
		], [ qw(wired active cache free other) ];
	}
	return [
		$m->{wired} || 0, $m->{active} || 0, $m->{cache} || 0,
		$m->{free} || 0, $m->{swapu} || 0, $m->{swapf} || 0,
	], [ qw(wired active cache free swapu swapf) ];
}

# --- draw ---

sub _hist_vec {
	my ($p) = @_;
	return [] unless $p;
	if (ref $p eq 'ARRAY') {
		return $p;
	}
	if (ref $p eq 'HASH') {
		if (exists $p->{wired} || exists $p->{npages}) {
			return [
				$p->{wired} || 0, $p->{active} || 0, $p->{cache} || 0,
				$p->{free} || 0, $p->{swapu} || 0, $p->{swapf} || 0,
			];
		}
		return [ $p->{a} || 0, $p->{b} || 0 ];
	}
	return [];
}

sub draw {
	my ($self, $X, $win, $gcs, $w, $h) = @_;
	return unless $X && $win && $w > 0 && $h > 0;
	my $bg = $gcs->{bg};
	my $fg = $gcs->{fg};
	my $series = $gcs->{series} || [ $gcs->{a}, $gcs->{b} ];
	$X->PolyFillRectangle($win, $bg, [ 0, 0, $w, $h ]) if $bg;
	my $left  = 12;
	my $right = 12;
	my $top   = 12;
	my $gw    = $w - $left - $right;
	my $gh    = $h - $top - 2;
	return if $gw < 4 || $gh < 4;

	my $style = $self->{style} || 'line';
	if ($style eq 'bar') {
		_draw_bars($self, $X, $win, $series, $left, $top, $gw, $gh);
	} elsif ($style eq 'stack') {
		_draw_stack($self, $X, $win, $series, $left, $top, $gw, $gh);
	} else {
		_draw_line($self, $X, $win, $series, $left, $top, $gw, $gh);
	}

	if ($fg) {
		$X->PolyLine($win, $fg, 'Origin',
			$left, $top + $gh, $left + $gw, $top + $gh);
		my $txt = $self->{input} . ' ' . $self->current_label;
		$txt = substr($txt, 0, 24) if length $txt > 24;
		eval { $X->ImageText8($win, $fg, $left + 2, $top - 2, $txt) };
		eval { $X->ImageText8($win, $fg, 2, int($h / 2) + 3, '<') };
		eval { $X->ImageText8($win, $fg, $w - 8, int($h / 2) + 3, '>') };
	}
}

sub _draw_line {
	my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
	my @hist = @{ $self->{hist} || [] };
	return unless @hist;
	my $max = 1;
	if ($self->{input} eq 'load') {
		$max = $self->{ncpu} || 1;
	}
	for my $p (@hist) {
		for my $v (@{ _hist_vec($p) }) {
			$max = $v if $v && $v > $max;
		}
	}
	my $n = @hist;
	my $use = $n < $gw ? $n : $gw;
	my $off = $n - $use;
	for my $i (0 .. $use - 1) {
		my $vec = _hist_vec($hist[ $off + $i ]);
		my $x = $left + $i;
		for my $j (0 .. $#$vec) {
			my $gc = $series->[$j] or next;
			my $hv = int($gh * ($vec->[$j] || 0) / $max);
			$hv = $gh if $hv > $gh;
			next unless $hv > 0;
			$X->PolyLine($win, $gc, 'Origin',
				$x, $top + $gh, $x, $top + $gh - $hv);
		}
	}
}

# Side-by-side bars, 1px background between entries.
sub _draw_bars {
	my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
	my $vec = _hist_vec($self->{cur} || $self->{hist}[-1]);
	return unless @$vec;
	my $n = @$vec;
	my $gap = 1;
	my $bw = int(($gw - ($n - 1) * $gap) / $n);
	$bw = 1 if $bw < 1;
	my $max = 1;
	if ($self->{input} eq 'load') {
		$max = $self->{ncpu} || 1;
	}
	for my $v (@$vec) {
		$max = $v if $v && $v > $max;
	}
	if ($self->{input} eq 'mem') {
		my $sum = 0;
		$sum += $_ for @$vec;
		$max = $sum if $sum > $max;
	}
	for my $j (0 .. $#$vec) {
		my $gc = $series->[$j] or next;
		my $hv = int($gh * ($vec->[$j] || 0) / $max);
		$hv = $gh if $hv > $gh;
		next unless $hv > 0;
		my $x = $left + $j * ($bw + $gap);
		$X->PolyFillRectangle($win, $gc, [ $x, $top + $gh - $hv, $bw, $hv ]);
	}
}

# Stacked bars: each history column is segments, 1px wide; current-only
# uses the full width as one stack (or ram|swap columns with 1px gap).
sub _draw_stack {
	my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
	my @hist = @{ $self->{hist} || [] };
	if ($self->{input} eq 'mem' && ($self->{view} || '') eq 'both' && @hist) {
		# Two stacks: RAM (wired/active/cache/free) | SWAP (used/free)
		my $m = $self->{cur} || {};
		my $mid = int($gw / 2);
		_fill_stack($X, $win, $series,
			[ $m->{wired} || 0, $m->{active} || 0, $m->{cache} || 0, $m->{free} || 0 ],
			$left, $top, $mid - 1, $gh);
		_fill_stack($X, $win, [ $series->[4], $series->[5] ],
			[ $m->{swapu} || 0, $m->{swapf} || 0 ],
			$left + $mid + 1, $top, $gw - $mid - 1, $gh);
		return;
	}
	if (@hist > 4 && $gw > 8) {
		my $use = @hist < $gw ? scalar @hist : $gw;
		my $off = @hist - $use;
		for my $i (0 .. $use - 1) {
			_fill_stack($X, $win, $series, _hist_vec($hist[ $off + $i ]),
				$left + $i, $top, 1, $gh);
		}
		return;
	}
	_fill_stack($X, $win, $series, _hist_vec($self->{cur} || $hist[-1]),
		$left, $top, $gw, $gh);
}

sub _fill_stack {
	my ($X, $win, $series, $vec, $x, $top, $bw, $gh) = @_;
	return unless $vec && @$vec && $bw > 0;
	my $sum = 0;
	$sum += ($_ || 0) for @$vec;
	return unless $sum > 0;
	my $y = $top + $gh;
	for my $j (0 .. $#$vec) {
		my $gc = $series->[$j] or next;
		my $hv = int($gh * ($vec->[$j] || 0) / $sum);
		$hv = $y - $top if $hv > $y - $top;
		next unless $hv > 0;
		$y -= $hv;
		$X->PolyFillRectangle($win, $gc, [ $x, $y, $bw, $hv ]);
	}
}

1;
