package Pldock::Plugin::Mixer;

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
use Pldock::Sndio;

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

# color0 bar, color1 mute, color2 label, color3 ticks
sub default_colors {
    return (0x66CC66, 0xCC6666, 0xFFFFFF, 0x888888);
}

sub parse_color {
    my ($s) = @_;
    return unless defined $s && length $s;
    $s =~ s/^#//;
    $s =~ s/^0x//i;
    return hex($s) if $s =~ /^[0-9a-fA-F]{6}$/;
    return $COLOR_NAME{ lc $s };
}

sub preferred_size { (120, 57) }

sub new {
    my ($class, %opt) = @_;
    my $freq = $opt{freq};
    $freq = 0.25 unless defined $freq && $freq > 0;
    $freq = 0.05 if $freq < 0.05;
    my @colors = @{ $opt{colors} || [] };
    @colors = map { parse_color($_) } @colors;
    @colors = grep { defined } @colors;
    my @def = default_colors();
    for my $i (0 .. 3) {
        $colors[$i] = $def[$i] unless defined $colors[$i];
    }
    my $sio = Pldock::Sndio->new;
    $sio->connect;
    return bless {
        freq        => $freq,
        colors      => \@colors,
        sio         => $sio,
        idx         => 0,
        faces       => [],
        next_sample => 0,
        step        => 0.05,
    }, $class;
}

sub input { 'mixer' }

sub current_label {
    my ($self) = @_;
    my $f = $self->_face or return 'input';
    return $f->{key};
}

sub due {
    my ($self) = @_;
    my $now = time();
    return 1 if !$self->{next_sample} || $now >= $self->{next_sample};
    return 0;
}

sub sample {
    my ($self) = @_;
    $self->{next_sample} = time() + ($self->{freq} || 0.25);
    my $sio = $self->{sio};
    unless ($sio && $sio->{sock}) {
        $sio ||= Pldock::Sndio->new;
        $sio->connect;
        $self->{sio} = $sio;
    }
    $sio->poll(0) if $sio && $sio->{sock};
    $self->_refresh_faces;
    return $self->_face;
}

sub _refresh_faces {
    my ($self) = @_;
    my @faces = $self->{sio} ? $self->{sio}->faces : ();
    unless (@faces) {
        @faces = ({ key => 'input', group => '', name => 'input' });
    }
    my $cur  = $self->{faces}[ $self->{idx} || 0 ];
    my $want = $cur && $cur->{key} ? $cur->{key} : 'input';
    $self->{faces} = \@faces;
    my $found = 0;
    for my $i (0 .. $#faces) {
        if ($faces[$i]{key} eq $want) {
            $self->{idx} = $i;
            $found = 1;
            last;
        }
    }
    unless ($found) {
        for my $i (0 .. $#faces) {
            if ($faces[$i]{key} eq 'input') {
                $self->{idx} = $i;
                $found = 1;
                last;
            }
        }
        $self->{idx} = 0 unless $found;
    }
}

sub _face {
    my ($self) = @_;
    my $fs = $self->{faces} || [];
    return unless @$fs;
    my $i = $self->{idx} || 0;
    $i = 0 if $i < 0 || $i > $#$fs;
    return $fs->[$i];
}

sub cycle {
    my ($self, $dir) = @_;
    $self->_refresh_faces;
    my $n = @{ $self->{faces} || [] } or return;
    $dir = $dir < 0 ? -1 : 1;
    $self->{idx} = (($self->{idx} || 0) + $dir) % $n;
}

sub face_keys {
    my ($self) = @_;
    return map { $_->{key} } @{ $self->{faces} || [] };
}

sub set_face {
    my ($self, $key) = @_;
    return unless defined $key;
    $self->_refresh_faces;
    my $fs = $self->{faces} || [];
    for my $i (0 .. $#$fs) {
        if ($fs->[$i]{key} eq $key) {
            $self->{idx} = $i;
            return;
        }
    }
}

# click($x,$y,$w,$h[,$button])
# button 4 = wheel up (louder), 5 = wheel down (quieter)
# left 14px / right 14px cycle faces
# title strip = group (all units)
# each slider = that unit; extras beyond what fits still follow the group hit
# mute strip under the bars
sub click {
    my ($self, $x, $y, $w, $h, $button) = @_;
    return 0 unless defined $x && $w;
    $button ||= 1;
    my $face = $self->_face;
    my $sio  = $self->{sio};
    my $L    = $self->_layout($w, $h);

    if ($button == 4) {
        $sio->apply_delta($face, $self->{step} || 0.05) if $sio && $face;
        return 1;
    }
    if ($button == 5) {
        $sio->apply_delta($face, -($self->{step} || 0.05)) if $sio && $face;
        return 1;
    }

    if ($x <= $L->{hit}) {
        $self->cycle(-1);
        return 1;
    }
    if ($x >= $w - $L->{hit}) {
        $self->cycle(1);
        return 1;
    }

    if ($y >= $L->{mute_y}) {
        $sio->toggle_mute($face) if $sio && $face;
        return 1;
    }

    my $unit;
    if ($y < $L->{title_h}) {
        $unit = undef;    # group
    }
    else {
        $unit = $self->_hit_slider($L, $y);
        return 1 unless defined $unit || $y >= $L->{title_h};
        # click in the gap above sliders still means group
        $unit = undef unless defined $unit;
    }

    $self->_set_bar($sio, $face, $L, $x, $unit);
    return 1;
}

sub _set_bar {
    my ($self, $sio, $face, $L, $x, $unit) = @_;
    return unless $sio && $face;
    my $left  = $L->{left};
    my $right = $L->{right};
    my $bw    = $right - $left;
    if ($x < $left + 6) {
        $sio->set_frac($face, 0, $unit);
    }
    elsif ($x > $right - 6) {
        $sio->set_frac($face, 1, $unit);
    }
    elsif ($bw > 0) {
        my $frac = ($x - $left) / $bw;
        $sio->set_frac($face, $frac, $unit);
    }
}

sub _hit_slider {
    my ($self, $L, $y) = @_;
    for my $s (@{ $L->{sliders} || [] }) {
        return $s->{unit} if $y >= $s->{top} && $y < $s->{top} + $s->{h};
    }
    return;
}

# member units (>=0) if any; otherwise the singleton (-1 / missing)
sub _slider_units {
    my ($face) = @_;
    my @u = Pldock::Sndio::face_units($face);
    my @mem = grep { $_ >= 0 } @u;
    return @mem if @mem;
    return @u    if @u;
    return (-1);
}

sub _layout {
    my ($self, $w, $h) = @_;
    $w ||= 1;
    $h ||= 1;
    my $hit = 14;
    $hit = int($w / 4) if $w < 56;
    $hit = 8 if $hit < 8;

    my $left  = $hit + 2;
    my $right = $w - $hit - 2;
    $right = $left + 8 if $right <= $left;

    my $title_h = 16;
    my $mute_h  = 12;
    my $top     = $title_h;
    my $bot     = $h - $mute_h;
    $bot = $top + 8 if $bot < $top + 8;

    my @units = _slider_units($self->_face);
    @units = (-1) unless @units;

    my $gap     = 2;
    my $min_bar = 6;
    my $avail   = $bot - $top;
    my $max_vis = int(($avail + $gap) / ($min_bar + $gap));
    $max_vis = 1 if $max_vis < 1;
    my $vis = @units > $max_vis ? $max_vis : scalar @units;
    $vis = 1 if $vis < 1;

    my $bar_h = int(($avail - ($vis - 1) * $gap) / $vis);
    $bar_h = $min_bar if $bar_h < $min_bar;

    my @sliders;
    for my $i (0 .. $vis - 1) {
        push @sliders, {
            unit => $units[$i],
            top  => $top + $i * ($bar_h + $gap),
            h    => $bar_h,
        };
    }

    return {
        hit      => $hit,
        left     => $left,
        right    => $right,
        title_h  => $title_h,
        mute_y   => $bot,
        sliders  => \@sliders,
        n_hidden => (@units > $vis) ? (@units - $vis) : 0,
    };
}

sub _frac {
    my ($self, $face, $unit) = @_;
    my $sio = $self->{sio};
    return 0 unless $sio && $face;
    my $f = $sio->frac($face, $unit);
    $f = 0 if $f < 0;
    $f = 1 if $f > 1;
    return $f;
}

sub _fmt3 { sprintf('%.3f', $_[0]) }

# "0.486" or "0.496(0.471,0.522)" — extra units appended, then clipped
sub _value_text {
    my ($self, $face, $maxch) = @_;
    $maxch ||= 20;
    my $g = _fmt3($self->_frac($face));
    my @mem = grep { $_ >= 0 } Pldock::Sndio::face_units($face);
    return $g unless @mem >= 2;

    my $txt = $g . '(' . join(',', map { _fmt3($self->_frac($face, $_)) } @mem) . ')';
    return $txt if length($txt) <= $maxch;

    # keep group + first two (L/R) so stereo still reads
    my $short = $g . '(' . join(',',
        _fmt3($self->_frac($face, $mem[0])),
        _fmt3($self->_frac($face, $mem[1])),
    );
    $short .= (@mem > 2) ? '+)' : ')';
    return $short;
}

sub _text {
    my ($X, $win, $gcs, $self, $idx, $x, $y, $str) = @_;
    return unless defined $str && length $str;
    my $fg = $gcs->{fg} or return;
    my $pix = $self->{colors}[$idx];
    eval { $X->ChangeGC($fg, foreground => $pix) } if defined $pix;
    eval { $X->ImageText8($win, $fg, $x, $y, $str) };
}

# Artificial mute (app/*): hardware level is 0, draw the pre-mute value.
sub _shown_frac {
    my ($self, $sio, $face) = @_;
    return 0 unless $sio && $face;

    if ($sio->is_muted($face) && !@{ $face->{mutes} || [] }) {
        my $saved = $face->{saved};
        my @lv    = @{ $face->{levels} || [] };
        if ($saved && @lv) {
            my ($sum, $n) = (0, 0);
            for my $i (0 .. $#lv) {
                my $max = $lv[$i]{maxval} || 1;
                my $v   = $saved->[$i];
                $sum += (defined $v ? $v : 0) / $max;
                $n++;
            }
            return $n ? $sum / $n : 0;
        }
    }
    return $sio->frac($face);
}



sub draw {
    my ($self, $X, $win, $gcs, $w, $h) = @_;
    return unless $X && $win && $w > 0 && $h > 0;
    my $bg = $gcs->{bg};
    $X->PolyFillRectangle($win, $bg, [ 0, 0, $w, $h ]) if $bg;

    my $face  = $self->_face;
    my $sio   = $self->{sio};
    my $label = $face ? $face->{key} : 'input';
    $label = substr($label, 0, 16) if length $label > 16;
    my $muted = $sio && $face ? $sio->is_muted($face) : 0;
    my $frac  = $self->_shown_frac($sio, $face);
    $frac = 0 if $frac < 0;
    $frac = 1 if $frac > 1;

    my $hit = 14;
    $hit = int($w / 4) if $w < 56;
    $hit = 8 if $hit < 8;

    _text($X, $win, $gcs, $self, 2, 2, 12, '<');
    _text($X, $win, $gcs, $self, 2, $w - 8, 12, '>');
    my $lw = length($label) * 6;
    my $lx = int(($w - $lw) / 2);
    $lx = $hit if $lx < $hit;
    _text($X, $win, $gcs, $self, 2, $lx, 12, $label);

    my $bar_top = 22;
    my $bar_h   = 14;
    my $left    = $hit + 2;
    my $right   = $w - $hit - 2;
    my $bw      = $right - $left;
    $bw = 8 if $bw < 8;

    if ($gcs->{fg}) {
        my $tick = $self->{colors}[3];
        eval { $X->ChangeGC($gcs->{fg}, foreground => $tick) } if defined $tick;
        $X->PolyLine($win, $gcs->{fg}, 'Origin',
            $left, $bar_top + $bar_h, $left + $bw, $bar_top + $bar_h);
        my $barc = $muted ? $self->{colors}[1] : $self->{colors}[0];
        eval { $X->ChangeGC($gcs->{fg}, foreground => $barc) } if defined $barc;
        my $fw = int($bw * $frac);
        $fw = 1 if $frac > 0 && $fw < 1;
        $X->PolyFillRectangle($win, $gcs->{fg},
            [ $left, $bar_top, $fw, $bar_h ]) if $fw > 0;
    }

    my $pct      = sprintf('%d%%', int($frac * 100 + 0.5));
    my $mute_txt = $muted ? 'MUTE' : 'mute';
    _text($X, $win, $gcs, $self, $muted ? 1 : 2, $left, $h - 4, $mute_txt);
    _text($X, $win, $gcs, $self, 2, $right - length($pct) * 6, $h - 4, $pct);
}

1;
