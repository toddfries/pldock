package Pldock::Sndio;

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

# Perl reimplementation of the sndioctl(1) control client against the
# sndiod AMSG protocol (lib/libsndio/amsg.h, aucat.c, sioctl_aucat.c).
# No fork of sndioctl(1).

use strict;
use warnings;
use IO::Socket::UNIX;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

use constant AMSG_ACK        => 0;
use constant AMSG_DATA       => 5;
use constant AMSG_HELLO      => 10;
use constant AMSG_AUTH       => 12;
use constant AMSG_CTLSET     => 14;
use constant AMSG_CTLSYNC    => 15;
use constant AMSG_CTLSUB     => 16;
use constant AMSG_VERSION    => 7;
use constant AMSG_TYPE_MAGIC => 0x40;
use constant AMSG_TYPE_SND   => 0;
use constant SIOCTL_READ     => 0x100;
use constant SIOCTL_WRITE    => 0x200;
use constant AMSG_SIZE       => 40;
use constant DESC_SIZE       => 128;
use constant SIOCTL_NONE     => 0;
use constant SIOCTL_NUM      => 2;
use constant SIOCTL_SW       => 3;
use constant SIOCTL_VEC      => 4;
use constant SIOCTL_LIST     => 5;
use constant SIOCTL_SEL      => 6;

sub new {
    my ($class, %opt) = @_;
    return bless {
        unit      => defined $opt{unit} ? $opt{unit} : 0,
        who       => substr($opt{who} || 'pldock', 0, 12),
        opt       => substr($opt{opt} || 'default', 0, 12),
        sock      => undef,
        err       => undef,
        ctls      => {},
        rbuf      => '',
        in_data   => 0,
        data_left => 0,
    }, $class;
}

sub error { $_[0]{err} }

sub sockpath {
    my ($self) = @_;
    my $uid  = $<;
    my $unit = $self->{unit} || 0;
    return sprintf('/tmp/sndio-%u/sock%u', $uid, $unit);
}

sub cookie {
    my $path = ($ENV{HOME} || '') . '/.sndio/cookie';
    if (open my $fh, '<', $path) {
        binmode $fh;
        my $n = read($fh, my $buf, 16);
        close $fh;
        return $buf if defined $n && $n == 16;
    }
    return;
}

sub _pack_amsg {
    my ($cmd, $body) = @_;
    $body = '' unless defined $body;
    $body .= "\xff" x 32;
    $body = substr($body, 0, 32);
    return pack('NNa32', $cmd, 0xffffffff, $body);
}

sub _send {
    my ($self, $bytes) = @_;
    my $s = $self->{sock} or return 0;
    my $off = 0;
    while ($off < length $bytes) {
        my $n = syswrite($s, $bytes, length($bytes) - $off, $off);
        return 0 unless defined $n && $n > 0;
        $off += $n;
    }
    return 1;
}

sub _recv_n {
    my ($self, $n) = @_;
    my $s = $self->{sock} or return;
    my $buf = '';
    while (length($buf) < $n) {
        my $got = sysread($s, my $chunk, $n - length($buf));
        return unless defined $got && $got > 0;
        $buf .= $chunk;
    }
    return $buf;
}

sub connect {
    my ($self) = @_;
    $self->disconnect;
    my $path = $self->sockpath;
    my $s = IO::Socket::UNIX->new(Peer => $path, Type => SOCK_STREAM);
    unless ($s) {
        $self->{err} = "sndio: $path: $!";
        return 0;
    }
    $s->autoflush(1);
    $self->{sock} = $s;

    my $cookie = cookie();
    unless (defined $cookie) {
        $self->{err} = 'sndio: no ~/.sndio/cookie';
        $self->disconnect;
        return 0;
    }

    my $auth_body = $cookie . ("\xff" x 16);
    return 0 unless $self->_send(_pack_amsg(AMSG_AUTH, $auth_body));

    my $hello = pack('n C C N a12 a12',
        SIOCTL_READ | SIOCTL_WRITE,
        AMSG_VERSION,
        AMSG_TYPE_MAGIC | AMSG_TYPE_SND,
        $$,
        pack('a12', $self->{opt}),
        pack('a12', $self->{who}),
    );
    return 0 unless $self->_send(_pack_amsg(AMSG_HELLO, $hello));

    my $ack = $self->_recv_n(AMSG_SIZE);
    unless (defined $ack) {
        $self->{err} = 'sndio: no HELLO ack';
        $self->disconnect;
        return 0;
    }
    my ($cmd) = unpack('N', $ack);
    unless ($cmd == AMSG_ACK) {
        $self->{err} = "sndio: HELLO refused (cmd $cmd)";
        $self->disconnect;
        return 0;
    }

    my $sub = pack('C C', 1, 1) . ("\xff" x 30);
    return 0 unless $self->_send(_pack_amsg(AMSG_CTLSUB, $sub));

    $self->{ctls}      = {};
    $self->{rbuf}      = '';
    $self->{in_data}   = 0;
    $self->{data_left} = 0;
    eval { $s->timeout(1.5) };
    $self->poll(1);
    eval { $s->timeout(0) };
    _nbio($s);
    return 1;
}

sub _nbio {
    my ($s) = @_;
    my $fl = fcntl($s, F_GETFL, 0);
    fcntl($s, F_SETFL, $fl | O_NONBLOCK) if defined $fl;
}

sub disconnect {
    my ($self) = @_;
    if ($self->{sock}) {
        CORE::close($self->{sock});
    }
    $self->{sock} = undef;
}

sub _parse_desc {
    my ($blob) = @_;
    return unless defined $blob && length($blob) >= DESC_SIZE;
    my ($n0, $u0n, $n1, $u1n, $func, $group, $type, $addr, $maxval, $curval, $display)
      = unpack('Z16 n x2 Z16 n x2 Z16 Z16 C x n n n x16 Z32', $blob);
    my $u0 = $u0n > 32767 ? $u0n - 65536 : $u0n;
    my $u1 = $u1n > 32767 ? $u1n - 65536 : $u1n;
    return {
        addr    => $addr,
        type    => $type,
        maxval  => $maxval,
        curval  => $curval,
        func    => $func || '',
        group   => $group || '',
        name    => $n0 || '',
        unit    => $u0,
        name1   => $n1 || '',
        unit1   => $u1,
        display => $display || '',
    };
}

sub _ingest_desc {
    my ($self, $c) = @_;
    return unless $c;
    if (($c->{type} || 0) == SIOCTL_NONE) {
        delete $self->{ctls}{ $c->{addr} };
        return;
    }
    $self->{ctls}{ $c->{addr} } = $c;
}

sub _ingest_msg {
    my ($self, $raw) = @_;
    return unless defined $raw && length($raw) >= 8;
    my ($cmd, undef, $body) = unpack('NNa32', $raw);
    if ($cmd == AMSG_CTLSET) {
        my ($addr, $val) = unpack('n n', $body);
        if (my $c = $self->{ctls}{$addr}) {
            $c->{curval} = $val;
        }
        return;
    }
    if ($cmd == AMSG_DATA) {
        my ($size) = unpack('N', $body);
        $self->{in_data}   = 1;
        $self->{data_left} = $size || 0;
        return;
    }
    if ($cmd == AMSG_CTLSYNC) {
        return;
    }
}

sub poll {
    my ($self, $blocking) = @_;
    my $s = $self->{sock} or return 0;
    my $got = 0;
    while (1) {
        my $need = $self->{in_data}
          ? ($self->{data_left} > 0 ? $self->{data_left} : DESC_SIZE)
          : AMSG_SIZE;
        my $have = length($self->{rbuf});
        if ($have < $need) {
            my $n = sysread($s, my $chunk, $need - $have);
            last unless defined $n && $n > 0;
            $self->{rbuf} .= $chunk;
            $got += $n;
        }
        if ($self->{in_data}) {
            while (length($self->{rbuf}) >= DESC_SIZE && $self->{data_left} >= DESC_SIZE) {
                my $blob = substr($self->{rbuf}, 0, DESC_SIZE, '');
                $self->{data_left} -= DESC_SIZE;
                $self->_ingest_desc(_parse_desc($blob));
            }
            if ($self->{data_left} <= 0) {
                $self->{in_data}   = 0;
                $self->{data_left} = 0;
            } else {
                last unless $blocking;
            }
            next;
        }
        if (length($self->{rbuf}) >= AMSG_SIZE) {
            my $msg = substr($self->{rbuf}, 0, AMSG_SIZE, '');
            $self->_ingest_msg($msg);
            next;
        }
        last;
    }
    return $got;
}

sub setval {
    my ($self, $addr, $val) = @_;
    return 0 unless $self->{sock};
    $val = 0 if $val < 0;
    my $c = $self->{ctls}{$addr};
    if ($c && defined $c->{maxval} && $val > $c->{maxval}) {
        $val = $c->{maxval};
    }
    my $body = pack('n n', $addr, $val) . ("\xff" x 28);
    return 0 unless $self->_send(_pack_amsg(AMSG_CTLSET, $body));
    $c->{curval} = $val if $c;
    return 1;
}

sub _levels {
    my ($face) = @_;
    return () unless $face;
    return @{ $face->{levels} || [] };
}

sub _mutes {
    my ($face) = @_;
    return () unless $face;
    return @{ $face->{mutes} || [] };
}

sub faces {
    my ($self) = @_;
    my %by;
    for my $c (values %{ $self->{ctls} }) {
        next unless $c->{func} eq 'level' || $c->{func} eq 'mute';
        my $g = $c->{group} || '';
        my $n = $c->{name}  || '';
        next unless length $n;
        my $key = $g ne '' ? "$g/$n" : $n;
        $by{$key} ||= {
            key    => $key,
            group  => $g,
            name   => $n,
            levels => [],
            mutes  => [],
        };
        if ($c->{func} eq 'level') {
            push @{ $by{$key}{levels} }, $c;
        } else {
            push @{ $by{$key}{mutes} }, $c;
        }
    }
    my @faces;
    my $push = sub {
        my ($f) = @_;
        return unless $f && @{ $f->{levels} || [] };
        $f->{level} = $f->{levels}[0];
        $f->{mute}  = $f->{mutes}[0] if @{ $f->{mutes} || [] };
        push @faces, $f;
    };
    $push->($by{input})  if $by{input};
    $push->($by{output}) if $by{output};
    for my $k (sort keys %by) {
        next if $k eq 'input' || $k eq 'output';
        next unless $k =~ m{^app/} || ($by{$k}{group} || '') eq 'app';
        $push->($by{$k});
    }
    return @faces;
}

sub apply_delta {
    my ($self, $face, $delta) = @_;
    my $ok = 0;
    for my $c (_levels($face)) {
        my $max = $c->{maxval} || 1;
        my $val = ($c->{curval} || 0)
          + int($delta * $max + ($delta >= 0 ? 0.5 : -0.5));
        $val = 0    if $val < 0;
        $val = $max if $val > $max;
        $ok++ if $self->setval($c->{addr}, $val);
    }
    return $ok;
}

sub set_frac {
    my ($self, $face, $frac) = @_;
    $frac = 0 if $frac < 0;
    $frac = 1 if $frac > 1;
    my $ok = 0;
    for my $c (_levels($face)) {
        $ok++ if $self->setval($c->{addr}, int($frac * ($c->{maxval} || 1) + 0.5));
    }
    return $ok;
}

sub toggle_mute {
    my ($self, $face) = @_;
    return 0 unless $face;
    my @mutes = _mutes($face);
    if (@mutes) {
        my $ok = 0;
        for my $m (@mutes) {
            my $max = $m->{maxval} || 1;
            $ok++ if $self->setval($m->{addr}, $m->{curval} ? 0 : $max);
        }
        return $ok;
    }
    my @lv = _levels($face) or return 0;
    if (_any_live(@lv)) {
        $face->{saved} = [ map { $_->{curval} } @lv ];
        my $ok = 0;
        for my $c (@lv) {
            $ok++ if $self->setval($c->{addr}, 0);
        }
        return $ok;
    }
    my $ok = 0;
    for my $i (0 .. $#lv) {
        my $restore = ($face->{saved} && defined $face->{saved}[$i] && $face->{saved}[$i] > 0)
          ? $face->{saved}[$i]
          : ($lv[$i]{maxval} || 1);
        $ok++ if $self->setval($lv[$i]{addr}, $restore);
    }
    return $ok;
}

sub _any_live {
    for my $c (@_) {
        return 1 if ($c->{curval} || 0) > 0;
    }
    return 0;
}

sub is_muted {
    my ($self, $face) = @_;
    return 0 unless $face;
    my @mutes = _mutes($face);
    if (@mutes) {
        for my $m (@mutes) {
            return 0 unless $m->{curval};
        }
        return 1;
    }
    return !_any_live(_levels($face));
}

sub frac {
    my ($self, $face) = @_;
    my @lv = _levels($face) or return 0;
    my ($sum, $n) = (0, 0);
    for my $c (@lv) {
        my $max = $c->{maxval} || 1;
        $sum += ($c->{curval} || 0) / $max;
        $n++;
    }
    return $n ? $sum / $n : 0;
}

1;
