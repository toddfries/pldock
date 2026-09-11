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
# bar: click sets fraction; far-left of bar = min; far-right = max
# mute strip under the bar
sub click {
    my ($self, $x, $y, $w, $h, $button) = @_;
    return 0 unless defined $x && $w;
    $button ||= 1;
    my $face = $self->_face;
    my $sio  = $self->{sio};

    if ($button == 4) {
        $sio->apply_delta($face, $self->{step} || 0.05) if $sio && $face;
        return 1;
    }
    if ($button == 5) {
        $sio->apply_delta($face, -($self->{step} || 0.05)) if $sio && $face;
        return 1;
    }

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

    my $bar_top = 22;
    my $bar_h   = 14;
    my $mute_y  = $bar_top + $bar_h + 2;
    my $left    = $hit + 2;
    my $right   = $w - $hit - 2;
    $right = $left + 8 if $right <= $left;

    if ($y >= $mute_y) {
        $sio->toggle_mute($face) if $sio && $face;
        return 1;
    }
    if ($y >= $bar_top && $y < $bar_top + $bar_h) {
        my $bw = $right - $left;
        if ($x < $left + 6) {
            $sio->set_frac($face, 0) if $sio && $face;
        } elsif ($x > $right - 6) {
            $sio->set_frac($face, 1) if $sio && $face;
        } elsif ($bw > 0) {
            my $frac = ($x - $left) / $bw;
            $sio->set_frac($face, $frac) if $sio && $face;
        }
        return 1;
    }
    return 0;
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

    my $face  = $self->_face;
    my $sio   = $self->{sio};
    my $label = $face ? $face->{key} : 'input';
    $label = substr($label, 0, 16) if length $label > 16;
    my $muted = $sio && $face ? $sio->is_muted($face) : 0;
    my $frac  = $sio && $face ? $sio->frac($face) : 0;
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
