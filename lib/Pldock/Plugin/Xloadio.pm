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
    unless ($style =~ /^(line|bar|stack|lanes|sidebyside)$/) {
	$style = $input eq 'mem'  ? 'stack'
          : $input eq 'load' ? 'sidebyside'
          :                    'line';
    }
    my $freq = $opt{freq};
    $freq = default_freq($input, $style) unless defined $freq && $freq > 0;
    $freq = 0.05 if $freq < 0.05;
    my @colors = @{ $opt{colors} || [] };
    @colors = map { parse_color($_) } @colors;
    @colors = grep { defined } @colors;
    my $names;
    $names = [ qw(read write) ] if $input eq 'disk';
    $names = [ qw(recv send) ] if $input eq 'net';
    $names = [ qw(1 5 15) ] if $input eq 'load';
    $names = [ qw(wired active cache free swapu swapf) ] if $input eq 'mem';
    return bless {
        input    => $input,
        style    => $style,
        freq     => $freq,
        idx      => 0,
        hist_by  => {},
        prev_by  => {},
        prev_t_by=> {},
        targets  => [ 'total' ],
        series   => $names,
        colors   => \@colors,
        ncpu     => _sysctl_int(CTL_HW(), HW_NCPU()) || 1,
        view     => 'both',
        next_sample => 0,
        want_3d  => $opt{want_3d} ? 1 : 0,
        spin     => undef,
    }, $class;
}

sub default_freq {
    my ($input, $style) = @_;
    return 0.25 if ($style || '') eq 'lanes';
    return 1;
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
    return $self->{held} if $self->{held};
    my $list = $self->{cycle_list} || $self->{targets} || [];
    my $t = $list->[ $self->{idx} || 0 ];
    return $t if defined $t && length $t;
    return 'total';
}

sub is_spinning { $_[0]{spin} ? 1 : 0 }

sub face_keys {
    my ($self) = @_;
    return qw(line bar stack lanes) if $self->{input} eq 'load';
    return qw(both ram swap) if $self->{input} eq 'mem';
    my $l = $self->{cycle_list} || $self->{targets} || [];
    return @$l ? @$l : ('total');
}

sub face_state {
    my ($self) = @_;
    return {
        idx   => $self->{idx},
        style => $self->{style},
        view  => $self->{view},
        held  => $self->{held},
    };
}

sub restore_face {
    my ($self, $st) = @_;
    return unless $st;
    $self->{idx}   = $st->{idx};
    $self->{style} = $st->{style};
    $self->{view}  = $st->{view};
    $self->{held}  = $st->{held};
}

sub set_face {
    my ($self, $key) = @_;
    return unless defined $key;
    if ($self->{input} eq 'load') {
        $self->{style} = $key;
        return;
    }
    if ($self->{input} eq 'mem') {
        $self->{view} = $key;
        return;
    }
    $self->{held} = undef;
    my @k = $self->face_keys;
    for my $i (0 .. $#k) {
        if ($k[$i] eq $key) {
            $self->{idx} = $i;
            return;
        }
    }
    $self->{held} = $key;
}

sub finish_spin {
    my ($self) = @_;
    my $sp = delete $self->{spin} or return;
    my $key = $sp->{keys}[ $sp->{to} ];
    $self->set_face($key) if defined $key;
}

sub cycle {
    my ($self, $dir) = @_;
    $dir = $dir < 0 ? -1 : 1;
    if ($self->{want_3d}) {
        return if $self->{spin};
        my @keys = $self->face_keys;
        if (@keys >= 2) {
            my $from = 0;
            my $cur  = $self->current_label;
            for my $i (0 .. $#keys) {
                $from = $i if $keys[$i] eq $cur;
            }
            my $to = ($from + $dir) % @keys;
            $self->{spin} = {
                t0   => time(),
                dur  => 2,
                dir  => $dir,
                from => $from,
                to   => $to,
                n    => scalar @keys,
                keys => \@keys,
            };
            return;
        }
    }
    if ($self->{input} eq 'load') {
        my @st = qw(sidebyside line bar stack lanes);
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
    $self->{held} = undef;
    my @t = @{ $self->{cycle_list} || $self->{targets} || [] };
    return unless @t;
    $self->{idx} = ($self->{idx} + $dir) % @t;
}

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

sub _hist_key {
    my ($self) = @_;
    return 'load' if $self->{input} eq 'load';
    return 'mem'  if $self->{input} eq 'mem';
    my $t = $self->current_label;
    return (defined $t && length $t) ? $t : 'total';
}

sub _rebuild_cycle_list {
    my ($self, $names) = @_;
    my $cur = $self->{held}
      || ($self->{cycle_list} && @{ $self->{cycle_list} }
          ? $self->{cycle_list}[ $self->{idx} || 0 ]
          : 'total');
    my @live = $self->live_cycle_list($names);
    $self->{cycle_list} = \@live;
    $self->{targets}    = \@live;
    my $found;
    for my $i (0 .. $#live) {
        if ($live[$i] eq $cur) {
            $self->{idx} = $i;
            $self->{held} = undef;
            $found = 1;
            last;
        }
    }
    $self->{held} = $cur unless $found;
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
            $m->{free} || 0,
        ], [ qw(wired active cache free) ];
    }
    return [
        $m->{wired} || 0, $m->{active} || 0, $m->{cache} || 0,
        $m->{free} || 0, $m->{swapu} || 0, $m->{swapf} || 0,
    ], [ qw(wired active cache free swapu swapf) ];
}

sub _mem_ram_vec {
    my ($m) = @_;
    $m ||= {};
    return [
        $m->{wired} || 0, $m->{active} || 0, $m->{cache} || 0,
        $m->{free} || 0,
    ];
}

sub _mem_swap_vec {
    my ($m) = @_;
    $m ||= {};
    return [ $m->{swapu} || 0, $m->{swapf} || 0 ];
}

sub live_cycle_list {
    my ($self, $names) = @_;
    $names ||= [];
    my $screen = $self->{last_gw} || 80;
    my @out = ('total');
    my %seen = ( total => 1 );
    for my $n (@$names) {
        next unless defined $n && length $n;
        next if $seen{$n}++;
        my $h = $self->{hist_by}{$n} || [];
        push @out, $n if hist_is_active($h, $screen);
    }
    return @out;
}

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

sub hist_is_active {
    my ($hist, $screen) = @_;
    return 0 unless $hist && @$hist;
    my $n = @$hist;
    $screen ||= $n;
    my $use = $screen < $n ? $screen : $n;
    my $nz = 0;
    for my $i ($n - $use .. $n - 1) {
        $nz++ if sample_nonzero($hist->[$i]);
        return 1 if $nz > 1;
    }
    return 0;
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

sub sample_nonzero {
    my ($p) = @_;
    return 0 unless $p;
    if (ref $p eq 'ARRAY') {
        for my $v (@$p) {
            return 1 if $v && $v > 0;
        }
        return 0;
    }
    if (ref $p eq 'HASH') {
        return 1 if ($p->{a} || 0) > 0 || ($p->{b} || 0) > 0;
        return 1 if exists $p->{wired} || exists $p->{npages};
    }
    return 0;
}

sub _hist_vec {
    my ($self, $p) = @_;
    return [] unless $p;
    if (ref $p eq 'ARRAY') {
        return $p;
    }
    if (ref $p eq 'HASH' && (exists $p->{wired} || exists $p->{npages})) {
        my ($vec) = $self->_mem_series($p);
        return $vec;
    }
    if (ref $p eq 'HASH') {
        return [ $p->{a} || 0, $p->{b} || 0 ];
    }
    return [];
}

# 2px bar per series, 1px gap between series, 2px gap between sample sets.
sub _sidebyside_metrics {
    my ($nser) = @_;
    $nser = 1 if !$nser || $nser < 1;
    my $bar_w   = 2;
    my $gap     = 1;
    my $set_gap = 2;
    my $set_w   = $nser * $bar_w + ($nser - 1) * $gap + $set_gap;
    return ($bar_w, $gap, $set_gap, $set_w);
}

sub _draw_sidebyside {
    my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
    my @hist = $self->_visible($gw, 'sidebyside');
    return unless @hist;

    my $nser = 0;
    for my $p (@hist) {
        my $n = @{ $self->_hist_vec($p) };
        $nser = $n if $n > $nser;
    }
    $nser = 3 if $self->{input} eq 'load' && $nser < 3;
    return unless $nser;

    my ($bar_w, $gap, undef, $set_w) = _sidebyside_metrics($nser);
    my $max = $self->_scale_max(@hist);
    $max = 1 if $max <= 0;

    for my $i (0 .. $#hist) {
        my $x0 = $left + $i * $set_w;
        last if $x0 >= $left + $gw;
        my $vec = $self->_hist_vec($hist[$i]);
        for my $j (0 .. $nser - 1) {
            my $gc = $series->[$j] or next;
            my $x  = $x0 + $j * ($bar_w + $gap);
            last if $x >= $left + $gw;
            my $hv = int($gh * ($vec->[$j] || 0) / $max);
            $hv = $gh if $hv > $gh;
            next unless $hv > 0;
            my $bw = $bar_w;
            $bw = $left + $gw - $x if $x + $bw > $left + $gw;
            next unless $bw > 0;
            $X->PolyFillRectangle($win, $gc,
                [ $x, $top + $gh - $hv, $bw, $hv ]);
        }
    }
}


sub _visible {
    my ($self, $gw, $style) = @_;
    my $h = $self->_hist;
    return () unless $h && @$h;
    $style ||= $self->{style} || 'line';
    my $use = $gw;
    if ($style eq 'lanes') {
        my $ng = int($gw / 6);
        $ng = 1 if $ng < 1;
        $use = $ng * 4;
    }
    $use = @$h if $use > @$h;
    return @$h[ -$use .. -1 ];
}

# Smallest 1/1.2/1.5/2/2.5/3/4/5/6/8/10 × 10^n that is >= $x.
# The old 1-2-5 steps jumped 2.1 → 5, so traces sat in the bottom 40%.
sub nice_ceil {
    my ($x) = @_;
    return 1 if !defined $x || $x <= 0;
    my $exp = int(log($x) / log(10));
    $exp-- if $x < 10 ** $exp;
    my $pow = 10 ** $exp;
    my $m   = $x / $pow;
    for my $n (1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10) {
        return $n * $pow if $m <= $n + 1e-12;
    }
    return 10 * $pow;
}

sub _fmt_bytes {
    my ($n) = @_;
    return '0B' if !defined $n || $n <= 0;
    my $v = $n;
    my $u = 'B';
    for my $unit (qw(KB MB GB TB)) {
        last if $v < 1024;
        $v /= 1024;
        $u = $unit;
    }
    return $v >= 100 ? sprintf('%.0f%s', $v, $u)
         : $v >= 10  ? sprintf('%.1f%s', $v, $u)
         :             sprintf('%.2f%s', $v, $u);
}

sub _fmt_scale {
    my ($self, $max) = @_;
    return '0' if !defined $max || $max <= 0;
    if ($self->{input} eq 'load') {
        return $max >= 10 ? sprintf('%.1f', $max) : sprintf('%.2f', $max);
    }
    return _fmt_bytes($max);
}

sub _fmt_mem_pool {
    my ($self) = @_;
    my $m = $self->{cur} || {};
    my $ps = $m->{pagesize} || 4096;
    my $view = $self->{view} || 'both';
    my $pages;
    if ($view eq 'swap') {
        $pages = $m->{swpages} || (($m->{swapu} || 0) + ($m->{swapf} || 0));
    } else {
        $pages = $m->{npages}
          || (($m->{wired} || 0) + ($m->{active} || 0)
            + ($m->{cache} || 0) + ($m->{free} || 0));
    }
    return _fmt_bytes($pages * $ps);
}

sub _title_text {
    my ($self, $gw, $style) = @_;
    my $base = $self->{input} . ' ' . $self->current_label;
    my $sc;
    if ($self->{input} eq 'mem') {
        $sc = $self->_fmt_mem_pool;
    } else {
        $sc = $self->_fmt_scale($self->_scale_max($self->_visible($gw, $style)));
    }
    return $sc unless length $base;
    my $txt = length($base) + 1 + length($sc) <= 18 ? "$base $sc" : $sc;
    $txt = substr($txt, 0, 24) if length $txt > 24;
    return $txt;
}

sub _scale_max {
    my ($self, @pts) = @_;
    my $max = 0;
    for my $p (@pts) {
        for my $v (@{ $self->_hist_vec($p) }) {
            $max = $v if defined $v && $v > $max;
        }
    }
    return nice_ceil($max);
}

sub _hist {
    my ($self) = @_;
    my $k = $self->_hist_key;
    $self->{hist_by}{$k} ||= [];
    return $self->{hist_by}{$k};
}

sub _trim_hist {
    my ($self, $arr) = @_;
    my $cap = 400;
    shift @$arr while @$arr > $cap;
}

sub due {
    my ($self) = @_;
    my $now = time();
    return 1 if !$self->{next_sample} || $now >= $self->{next_sample};
    return 0;
}

sub sample {
    my ($self) = @_;
    my $now = time();
    $self->{next_sample} = $now + ($self->{freq} || 1);
    if ($self->{input} eq 'load') {
        my $v = _load_values();
        my $h = $self->_hist;
        push @$h, $v;
        $self->_trim_hist($h);
        $self->{cur} = $v;
        return $v;
    }
    if ($self->{input} eq 'mem') {
        my $v = _mem_values();
        my $h = $self->_hist;
        push @$h, $v;
        $self->_trim_hist($h);
        $self->{cur} = $v;
        return $v;
    }
    my ($vals, $names);
    if ($self->{input} eq 'net') {
        ($vals, $names) = _net_counters();
    } else {
        ($vals, $names) = _disk_counters();
    }
    $self->_rebuild_cycle_list($names);
    my $key = $self->_hist_key;
    my $pair = $vals->{$key} || { a => 0, b => 0 };
    my $prev = $self->{prev_by}{$key};
    my $prev_t = $self->{prev_t_by}{$key} || 0;
    my $dt = $prev_t ? ($now - $prev_t) : 0;
    my $rate = [ 0, 0 ];
    if ($dt > 0.05 && $prev) {
        $rate->[0] = ($pair->{a} - $prev->{a}) / $dt;
        $rate->[1] = ($pair->{b} - $prev->{b}) / $dt;
        $rate->[0] = 0 if $rate->[0] < 0;
        $rate->[1] = 0 if $rate->[1] < 0;
        my $h = $self->_hist;
        push @$h, $rate;
        $self->_trim_hist($h);
    }
    $self->{prev_by}{$key}   = $pair;
    $self->{prev_t_by}{$key} = $now;
    $self->{cur}             = $rate;
    return $rate;
}

sub draw {
    my ($self, $X, $win, $gcs, $w, $h) = @_;
    return unless $X && $win && $w > 0 && $h > 0;
    my $bg = $gcs->{bg};
    my $fg = $gcs->{fg};
    my $grid = $gcs->{grid};
    my $series = $gcs->{series} || [ $gcs->{a}, $gcs->{b} ];
    $X->PolyFillRectangle($win, $bg, [ 0, 0, $w, $h ]) if $bg;
    $self->{last_w}  = $w;
    $self->{last_gw} = ($w > 24) ? ($w - 24) : $w;
    my $left  = 12;
    my $right = 12;
    my $top   = 12;
    my $gw    = $w - $left - $right;
    my $gh    = $h - $top - 2;
    return if $gw < 4 || $gh < 4;

    my $style = $self->{style} || 'line';
    _draw_grid($X, $win, $grid, $left, $top, $gw, $gh) if $grid && $style ne 'lanes';
    if ($style eq 'bar') {
        _draw_bars($self, $X, $win, $series, $left, $top, $gw, $gh);
    } elsif ($style eq 'stack') {
        _draw_stack($self, $X, $win, $series, $left, $top, $gw, $gh);
    } elsif ($style eq 'lanes') {
        _draw_lanes($self, $X, $win, $series, $grid, $left, $top, $gw, $gh);
    } elsif ($style eq 'sidebyside') {
	_draw_sidebyside($self, $X, $win, $series, $left, $top, $gw, $gh);
    } else {
        _draw_line($self, $X, $win, $series, $left, $top, $gw, $gh);
    }

    if ($fg) {
        $X->PolyLine($win, $fg, 'Origin',
            $left, $top + $gh, $left + $gw, $top + $gh);
        my $txt = $self->_title_text($gw, $style);
        eval { $X->ImageText8($win, $fg, $left + 2, $top - 2, $txt) };
        eval { $X->ImageText8($win, $fg, 2, int($h / 2) + 3, '<') };
        eval { $X->ImageText8($win, $fg, $w - 8, int($h / 2) + 3, '>') };
    }
}

sub _draw_grid {
    my ($X, $win, $grid, $left, $top, $gw, $gh) = @_;
    return unless $grid && $gh > 8;
    for my $d (1 .. 3) {
        my $y = $top + $gh - int($gh * $d / 4);
        $X->PolyLine($win, $grid, 'Origin', $left, $y, $left + $gw, $y);
    }
}

sub _draw_line {
    my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
    my @hist = $self->_visible($gw, 'line');
    return unless @hist;
    my $max = $self->_scale_max(@hist);
    $max = 1 if $max <= 0;
    for my $i (0 .. $#hist) {
        my $vec = $self->_hist_vec($hist[$i]);
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

sub _draw_bars {
    my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
    my $vec = $self->_hist_vec($self->{cur} || ($self->_hist)->[-1]);
    return unless @$vec;
    my $n = @$vec;
    my $gap = 1;
    my $bw = int(($gw - ($n - 1) * $gap) / $n);
    $bw = 1 if $bw < 1;
    my $max = $self->_scale_max($self->{cur} || ($self->_hist)->[-1]);
    if ($self->{input} eq 'mem') {
        my $sum = 0;
        $sum += $_ for @$vec;
        $max = $sum if $sum > 0;
    }
    $max = 1 if $max <= 0;
    for my $j (0 .. $#$vec) {
        my $gc = $series->[$j] or next;
        my $hv = int($gh * ($vec->[$j] || 0) / $max);
        $hv = $gh if $hv > $gh;
        next unless $hv > 0;
        my $x = $left + $j * ($bw + $gap);
        $X->PolyFillRectangle($win, $gc, [ $x, $top + $gh - $hv, $bw, $hv ]);
    }
}

sub _draw_stack {
    my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
    if ($self->{input} eq 'mem') {
        _draw_mem_stack($self, $X, $win, $series, $left, $top, $gw, $gh);
        return;
    }
    my @hist = $self->_visible($gw, 'stack');
    if (@hist > 4 && $gw > 8) {
        for my $i (0 .. $#hist) {
            _fill_stack($X, $win, $series, $self->_hist_vec($hist[$i]),
                $left + $i, $top, 1, $gh);
        }
        return;
    }
    _fill_stack($X, $win, $series, $self->_hist_vec($self->{cur} || $hist[-1]),
        $left, $top, $gw, $gh);
}

sub _draw_mem_stack {
    my ($self, $X, $win, $series, $left, $top, $gw, $gh) = @_;
    my $view = $self->{view} || 'both';
    my @hist = $self->_visible($gw, 'stack');
    unless (@hist) {
        my $m = $self->{cur} || {};
        @hist = ($m) if %$m;
    }
    return unless @hist;

    if ($view eq 'both') {
        my $mid = int($gw / 2);
        my $lw  = $mid > 1 ? $mid - 1 : 1;
        my $rx  = $left + $mid + 1;
        my $rw  = $gw - $mid - 1;
        $rw = 1 if $rw < 1;
        my @lh = @hist;
        @lh = @lh[ -$lw .. -1 ] if @lh > $lw;
        my @rh = @hist;
        @rh = @rh[ -$rw .. -1 ] if @rh > $rw;
        for my $i (0 .. $#lh) {
            _fill_stack($X, $win, $series, _mem_ram_vec($lh[$i]),
                $left + $i, $top, 1, $gh);
        }
        for my $i (0 .. $#rh) {
            _fill_stack($X, $win, [ $series->[4], $series->[5] ],
                _mem_swap_vec($rh[$i]),
                $rx + $i, $top, 1, $gh);
        }
        return;
    }

    if ($view eq 'swap') {
        my @h = @hist;
        @h = @h[ -$gw .. -1 ] if @h > $gw;
        if (@h > 4 && $gw > 8) {
            for my $i (0 .. $#h) {
                _fill_stack($X, $win, [ $series->[4], $series->[5] ],
                    _mem_swap_vec($h[$i]), $left + $i, $top, 1, $gh);
            }
            return;
        }
        _fill_stack($X, $win, [ $series->[4], $series->[5] ],
            _mem_swap_vec($self->{cur} || $h[-1]), $left, $top, $gw, $gh);
        return;
    }

    my @h = @hist;
    @h = @h[ -$gw .. -1 ] if @h > $gw;
    if (@h > 4 && $gw > 8) {
        for my $i (0 .. $#h) {
            _fill_stack($X, $win, $series, _mem_ram_vec($h[$i]),
                $left + $i, $top, 1, $gh);
        }
        return;
    }
    _fill_stack($X, $win, $series, _mem_ram_vec($self->{cur} || $h[-1]),
        $left, $top, $gw, $gh);
}

sub _draw_lanes {
    my ($self, $X, $win, $series, $grid, $left, $top, $gw, $gh) = @_;
    my @hist = $self->_visible($gw, 'lanes');
    return unless @hist;
    my $nser = 0;
    for my $p (@hist) {
        my $n = @{ $self->_hist_vec($p) };
        $nser = $n if $n > $nser;
    }
    $nser = 3 if $self->{input} eq 'load' && $nser < 3;
    return unless $nser;
    my $lane_gap = 1;
    my $lane_h = int(($gh - ($nser - 1) * $lane_gap) / $nser);
    return if $lane_h < 2;
    my $max = $self->_scale_max(@hist);
    $max = 1 if $max <= 0;
    for my $j (0 .. $nser - 1) {
        my $ly = $top + $j * ($lane_h + $lane_gap);
        if ($grid) {
            for my $d (1 .. 3) {
                my $y = $ly + $lane_h - int($lane_h * $d / 4);
                $X->PolyLine($win, $grid, 'Origin',
                    $left, $y, $left + $gw, $y);
            }
        }
        for my $i (0 .. $#hist) {
            my $vec = $self->_hist_vec($hist[$i]);
            my $g = int($i / 4);
            my $x = $left + $g * 6 + ($i % 4);
            last if $x >= $left + $gw;
            my $gc = $series->[$j] or next;
            my $hv = int($lane_h * ($vec->[$j] || 0) / $max);
            $hv = $lane_h if $hv > $lane_h;
            next unless $hv > 0;
            $X->PolyLine($win, $gc, 'Origin',
                $x, $ly + $lane_h, $x, $ly + $lane_h - $hv);
        }
    }
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

sub _sysctl_int {
    my ($a, $b) = @_;
    my $mib = pack('ii', $a, $b);
    my $buf = pack('i!', 0);
    my $olen = pack('L!', length $buf);
    return unless syscall(SYS_sysctl(), $mib, 2, $buf, $olen, 0, 0) == 0;
    return unpack('i!', $buf);
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

1;
