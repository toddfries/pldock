package Pldock::Plugin::Clock;

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

# Coordinated Stardate (stardate.grok.me):
#   minutes since 1961-04-12 00:00:00 UTC / 10000
#   epoch is Vostok 1 / Yuri Gagarin
use constant CSD_UNIX => -275270400;
use constant CSD_DIV  => 600_000;    # 10000 minutes in seconds
use constant LAB_W    => 18;         # 3 glyphs of 6x13
use constant GAP      => 4;          # px between label and day digits
use constant PAD      => 2;          # px past each outer Month/DOW edge

my %COLOR_NAME = (
    green   => 0x66CC66,
    yellow  => 0xCCCC44,
    red     => 0xCC6666,
    cyan    => 0x66CCCC,
    orange  => 0xCC8844,
    gray    => 0x888888,
    grey    => 0x888888,
    blue    => 0x4488CC,
    magenta => 0xCC66CC,
    white   => 0xFFFFFF,
    black   => 0x000000,
);

# color0 time, color1 month, color2 day, color3 dow, color4 stardate
sub default_colors {
    return (0x66CCCC, 0xCCCC44, 0xFFFFFF, 0x66CC66, 0xCC8844);
}

sub parse_color {
    my ($s) = @_;
    return unless defined $s && length $s;
    $s =~ s/^#//;
    $s =~ s/^0x//i;
    return hex($s) if $s =~ /^[0-9a-fA-F]{6}$/;
    return $COLOR_NAME{ lc $s };
}

sub _digit_scale {
    my ($h) = @_;
    $h = 57 unless defined $h && $h > 0;
    return 3 if $h >= 52;
    return 2 if $h >= 40;
    return 1;
}

sub _day_w {
    my ($s) = @_;
    $s = 3 unless defined $s && $s > 0;
    return 2 * (5 * $s) + ($s > 1 ? 2 : 1);
}

sub _cluster_w {
    my ($s) = @_;
    return LAB_W + GAP + _day_w($s) + GAP + LAB_W;
}

sub preferred_size {
    my ($class, $h) = @_;
    $h = 57 unless defined $h && $h > 0;
    my $s = _digit_scale($h);
    my $w = _cluster_w($s) + 2 * PAD;
    return ($w, $h);
}

sub new {
    my ($class, %opt) = @_;
    my $style = lc($opt{style} || '');
    my $show_sec = ($style eq 'sec' || $style eq 'seconds' || $opt{show_sec}) ? 1 : 0;
    my $freq = $opt{freq};
    $freq = 1 unless defined $freq && $freq > 0;
    $freq = 0.05 if $freq < 0.05;
    my @colors = @{ $opt{colors} || [] };
    @colors = map { parse_color($_) } @colors;
    @colors = grep { defined } @colors;
    my @def = default_colors();
    for my $i (0 .. 4) {
        $colors[$i] = $def[$i] unless defined $colors[$i];
    }
    return bless {
        freq     => $freq,
        show_sec => $show_sec,
        colors   => \@colors,
        next_sample => 0,
        parts    => {},
    }, $class;
}

sub input { 'clock' }

sub current_label {
    my ($self) = @_;
    return $self->{show_sec} ? 'sec' : 'min';
}

sub due {
    my ($self) = @_;
    my $now = time();
    return 1 if !$self->{next_sample} || $now >= $self->{next_sample};
    return 0;
}

sub sample {
    my ($self, $when) = @_;
    $when = time() unless defined $when;
    my $step = $self->{freq} || 1;
    if (!$self->{show_sec} && $step >= 15) {
        my $rem = 60 - ((int $when) % 60);
        $step = $rem if $rem > 0 && $rem < $step;
    }
    $self->{next_sample} = $when + $step;
    $self->{parts} = $self->parts_at($when);
    return $self->{parts};
}

sub parts_at {
    my ($self, $when) = @_;
    $when = time() unless defined $when;
    my $unix = int($when);
    my @t = localtime($unix);
    my @mon = qw(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC);
    my @dow = qw(SUN MON TUE WED THU FRI SAT);
    my $hour = $t[2];
    my $min  = $t[1];
    my $sec  = $t[0];
    my $time = $self->{show_sec}
      ? sprintf('%02d:%02d:%02d', $hour, $min, $sec)
      : sprintf('%02d:%02d', $hour, $min);
    return {
        unix     => $unix,
        time     => $time,
        hour     => $hour,
        min      => $min,
        sec      => $sec,
        dow      => $dow[ $t[6] ],
        day      => sprintf('%02d', $t[3]),
        mon      => $mon[ $t[4] ],
        year     => $t[5] + 1900,
        stardate => stardate($unix),
    };
}

sub stardate {
    my ($unix) = @_;
    $unix = time() unless defined $unix;
    return sprintf('%.6f', ($unix - CSD_UNIX) / CSD_DIV);
}

sub cycle {
    my ($self, $dir) = @_;
    $self->{show_sec} = $self->{show_sec} ? 0 : 1;
    $self->{next_sample} = 0;
    return $self->{show_sec};
}

sub click {
    my ($self, $x, $y, $w, $h) = @_;
    return 0 unless defined $x && $w;
    $self->cycle(1);
    return 1;
}

sub face_keys { qw(min sec) }

sub set_face {
    my ($self, $key) = @_;
    return unless defined $key;
    $self->{show_sec} = ($key eq 'sec' || $key eq 'seconds') ? 1 : 0;
    $self->{next_sample} = 0;
}

my @DIGIT = (
    [ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E ],
    [ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E ],
    [ 0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F ],
    [ 0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E ],
    [ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 ],
    [ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E ],
    [ 0x0E, 0x11, 0x10, 0x1E, 0x11, 0x11, 0x0E ],
    [ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 ],
    [ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E ],
    [ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x11, 0x0E ],
);

sub _draw_digit {
    my ($X, $win, $gc, $x, $y, $d, $s) = @_;
    return unless $gc && $d >= 0 && $d <= 9;
    my $rows = $DIGIT[$d] or return;
    my @rects;
    for my $r (0 .. 6) {
        my $bits = $rows->[$r];
        for my $c (0 .. 4) {
            next unless $bits & (1 << (4 - $c));
            push @rects, [ $x + $c * $s, $y + $r * $s, $s, $s ];
        }
    }
    $X->PolyFillRectangle($win, $gc, @rects) if @rects;
}

sub _draw_day {
    my ($X, $win, $gc, $cx, $y, $day, $s) = @_;
    $day =~ s/\D//g;
    $day = sprintf('%02d', 0 + ($day || 0));
    my $dw = 5 * $s;
    my $gap = $s > 1 ? 2 : 1;
    my $total = 2 * $dw + $gap;
    my $x = $cx - int($total / 2);
    _draw_digit($X, $win, $gc, $x, $y, substr($day, 0, 1), $s);
    _draw_digit($X, $win, $gc, $x + $dw + $gap, $y, substr($day, 1, 1), $s);
    return ($total, 7 * $s);
}

sub _text {
    my ($X, $win, $gcs, $self, $idx, $x, $y, $str) = @_;
    return unless defined $str && length $str;
    my $fg = $gcs->{fg} or return;
    my $pix = $self->{colors}[$idx];
    eval { $X->ChangeGC($fg, foreground => $pix) } if defined $pix;
    eval { $X->ImageText8($win, $fg, $x, $y, $str) };
}

sub draw {
    my ($self, $X, $win, $gcs, $w, $h) = @_;
    return unless $X && $win && $w > 0 && $h > 0;
    my $bg = $gcs->{bg};
    $X->PolyFillRectangle($win, $bg, [ 0, 0, $w, $h ]) if $bg;

    my $p = $self->{parts};
    $p = $self->parts_at(time()) unless $p && $p->{time};

    my $s     = _digit_scale($h);
    my $day_w = _day_w($s);
    my $day_h = 7 * $s;
    my $top   = 11;
    my $sd_h  = 13;
    my $bot   = $h - 3;
    $bot = $sd_h if $bot < $sd_h;

    my $mid_y = int(($h - $day_h) / 2);
    $mid_y = $top + 2 if $mid_y < $top + 2;
    if ($mid_y + $day_h > $bot - $sd_h) {
        $mid_y = $bot - $sd_h - $day_h;
        $mid_y = 1 if $mid_y < 1;
    }

    my $cx = int($w / 2);

    my $txt = $p->{time};
    my $tw  = length($txt) * 6;
    my $tx  = int(($w - $tw) / 2);
    $tx = PAD if $tx < PAD;
    _text($X, $win, $gcs, $self, 0, $tx, $top, $txt);

    if ($gcs->{fg}) {
        my $pix = $self->{colors}[2];
        eval { $X->ChangeGC($gcs->{fg}, foreground => $pix) } if defined $pix;
        _draw_day($X, $win, $gcs->{fg}, $cx, $mid_y, $p->{day}, $s);
    }

    my $side_y = $mid_y + int($day_h / 2) + 4;
    $side_y = $mid_y + 13 if $side_y < $mid_y + 8;
    $side_y = $bot - 2 if $side_y > $bot - 2;

    my $mon_x = $cx - int($day_w / 2) - GAP - LAB_W;
    my $dow_x = $cx + int($day_w / 2) + GAP;
    $mon_x = PAD if $mon_x < PAD;
    _text($X, $win, $gcs, $self, 1, $mon_x, $side_y, $p->{mon});
    _text($X, $win, $gcs, $self, 3, $dow_x, $side_y, $p->{dow});

    my $sd = $p->{stardate};
    my $sw = length($sd) * 6;
    my $sx = int(($w - $sw) / 2);
    $sx = PAD if $sx < PAD;
    _text($X, $win, $gcs, $self, 4, $sx, $bot, $sd);
}

1;
