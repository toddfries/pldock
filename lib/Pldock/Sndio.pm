package Pldock::Sndio;

# Copyright (c) 2026 Todd T. Fries <todd@fries.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.

use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Time::HiRes qw(time);

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
        synced    => 0,
    }, $class;
}

sub error  { $_[0]{err} }
sub synced { $_[0]{synced} }

sub sockpaths {
    my ($self) = @_;
    my $uid  = $<;
    my $unit = $self->{unit} || 0;
    return (
        sprintf('/tmp/sndio-%u/sock%u', $uid, $unit),
        sprintf('/tmp/sndio/sock%u', $unit),
    );
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
        unless (defined $n && $n > 0) {
            $self->{err} = "sndio: write: $!";
            return 0;
        }
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

sub _wait_readable {
    my ($self, $timeout) = @_;
    my $s = $self->{sock} or return 0;
    my $sel = IO::Select->new($s);
    my @r = $sel->can_read($timeout);
    return @r ? 1 : 0;
}

sub connect {
    my ($self) = @_;
    $self->disconnect;
    $self->{err} = undef;
    my $s;
    my @tried;
    for my $path ($self->sockpaths) {
        push @tried, $path;
        $s = IO::Socket::UNIX->new(Peer => $path, Type => SOCK_STREAM);
        last if $s;
    }
    unless ($s) {
        $self->{err} = 'sndio: connect ' . join(', ', @tried) . ": $!";
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

    return 0 unless $self->_send(_pack_amsg(AMSG_AUTH, $cookie . ("\xff" x 16)));

    my $hello = pack('n C C N a12 a12',
        SIOCTL_READ | SIOCTL_WRITE,
        AMSG_VERSION,
        AMSG_TYPE_MAGIC | AMSG_TYPE_SND,
        $$,
        pack('a12', $self->{opt}),
        pack('a12', $self->{who}),
    );
    return 0 unless $self->_send(_pack_amsg(AMSG_HELLO, $hello));

    unless ($self->_wait_readable(2)) {
        $self->{err} = 'sndio: HELLO timeout';
        $self->disconnect;
        return 0;
    }
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
    $self->{synced}    = 0;

    my $end = time() + 2.5;
    while (!$self->{synced} && time() < $end) {
        last unless $self->_wait_readable($end - time());
        $self->poll;
    }
    unless ($self->{synced}) {
        $self->{err} = 'sndio: no CTLSYNC (got '
          . (scalar keys %{ $self->{ctls} }) . ' controls)';
    }
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
    CORE::close($self->{sock}) if $self->{sock};
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
        $self->{synced} = 1;
        return;
    }
}

sub poll {
    my ($self) = @_;
    my $s = $self->{sock} or return 0;
    my $got = 0;
    while (1) {
        my $need = $self->{in_data}
          ? ($self->{data_left} > 0 ? $self->{data_left} : 1)
          : AMSG_SIZE;
        my $have = length($self->{rbuf});
        if ($have < $need) {
            my $n = sysread($s, my $chunk, ($need - $have) > 4096 ? 4096 : ($need - $have));
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
                last;
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
    $val = int($val + 0);
    my $body = pack('n n', $addr, $val) . ("\xff" x 28);
    return 0 unless $self->_send(_pack_amsg(AMSG_CTLSET, $body));
    $c->{curval} = $val if $c;
    return 1;
}

sub controls { values %{ $_[0]{ctls} } }

sub _cmpctl {
    my ($a, $b) = @_;
    my $r = ($a->{group} cmp $b->{group})
      || ($a->{name}  cmp $b->{name})
      || (($a->{type} || 0) <=> ($b->{type} || 0))
      || ($a->{func}  cmp $b->{func})
      || (($a->{unit} || 0) <=> ($b->{unit} || 0));
    return $r unless $r == 0;
    return ($a->{name1} cmp $b->{name1})
      || (($a->{unit1} || 0) <=> ($b->{unit1} || 0));
}

sub sorted_controls {
    my ($self) = @_;
    return sort { _cmpctl($a, $b) } values %{ $self->{ctls} };
}

sub _same_func {
    my ($a, $b) = @_;
    return $a && $b
      && $a->{group} eq $b->{group}
      && $a->{name}  eq $b->{name}
      && $a->{func}  eq $b->{func};
}

sub _print_node {
    my ($name, $unit, $mono) = @_;
    $name = '' unless defined $name;
    if (!$mono && defined $unit && $unit >= 0) {
        return sprintf('%s[%d]', $name, $unit);
    }
    return $name;
}

sub _print_display {
    my ($d) = @_;
    return '' unless defined $d && length $d;
    $d =~ s/[()]//g;
    $d =~ s/[[:cntrl:]]//g;
    return length($d) ? "($d)" : '';
}

sub _print_num {
    my ($c) = @_;
    my $max = $c->{maxval} || 1;
    if ($max == 1) {
        return sprintf('%d', $c->{curval} || 0);
    }
    return sprintf('%.3f', ($c->{curval} || 0) / $max);
}

sub format_par {
    my ($self, $rows, %opt) = @_;
    $rows = [$rows] if ref($rows) eq 'HASH';
    return '' unless $rows && @$rows;
    my $head  = $rows->[0];
    my $mono  = defined $opt{mono} ? $opt{mono} : 1;
    my $nflag = $opt{nflag} || 0;
    my $s     = '';
    unless ($nflag) {
        $s .= $head->{group} . '/' if $head->{group};
        $s .= _print_node($head->{name}, $head->{unit}, $mono);
        $s .= '.' . $head->{func} . '=';
    }
    my $type = $head->{type} || 0;
    if ($type == SIOCTL_NUM || $type == SIOCTL_SW) {
        $s .= _print_num($head);
        $s .= _print_display($head->{display});
    } else {
        my @bits;
        my %seen;
        for my $e (@$rows) {
            if ($mono) {
                next if defined $e->{unit} && defined $e->{unit1}
                  && $e->{unit} >= 0 && $e->{unit1} >= 0
                  && $e->{unit} != $e->{unit1};
                my $k = $e->{name1} . "\0" . ($e->{unit1} // '');
                next if $seen{$k}++;
            }
            my $max = $e->{maxval} || 1;
            if ($max == 1) {
                next unless $e->{curval};
                push @bits, _print_node($e->{name1}, $e->{unit1}, $mono)
                  . _print_display($e->{display});
            } else {
                push @bits, _print_node($e->{name1}, $e->{unit1}, $mono)
                  . ':' . _print_num($e) . _print_display($e->{display});
            }
        }
        $s .= join(',', @bits);
    }
    return $s;
}

sub list_lines {
    my ($self, %opt) = @_;
    my @all = $self->sorted_controls;
    my @out;
    my $i = 0;
    while ($i <= $#all) {
        my $g   = $all[$i];
        my @grp = ($g);
        my $j   = $i + 1;
        while ($j <= $#all && _same_func($g, $all[$j])) {
            push @grp, $all[$j];
            $j++;
        }
        my $mono = $opt{verbose} ? 0 : _ismono(\@grp);
        if ($opt{verbose} || !$mono) {
            my %byu;
            for my $c (@grp) {
                my $u = defined $c->{unit} ? $c->{unit} : -1;
                push @{ $byu{$u} }, $c;
            }
            for my $u (sort { $a <=> $b } keys %byu) {
                push @out, $self->format_par($byu{$u}, mono => 0, nflag => $opt{nflag});
            }
        } else {
            push @out, $self->format_par(\@grp, mono => 1, nflag => $opt{nflag});
        }
        $i = $j;
    }
    return @out;
}

sub _ismono {
    my ($grp) = @_;
    return 1 unless $grp && @$grp;
    my $p1 = $grp->[0];
    my $t  = $p1->{type} || 0;
    if ($t == SIOCTL_NUM || $t == SIOCTL_SW) {
        for my $p2 (@$grp) {
            return 0 if ($p2->{curval} || 0) != ($p1->{curval} || 0);
        }
        return 1;
    }
    my %diag;
    for my $e (@$grp) {
        my $off = (defined $e->{unit} && defined $e->{unit1}
          && $e->{unit} >= 0 && $e->{unit1} >= 0
          && $e->{unit} != $e->{unit1});
        if ($off) {
            return 0 if $e->{curval};
            next;
        }
        my $k = $e->{name1};
        if (exists $diag{$k}) {
            return 0 if ($diag{$k}{curval} || 0) != ($e->{curval} || 0);
            return 0 if ($diag{$k}{display} || '') ne ($e->{display} || '');
        } else {
            $diag{$k} = $e;
        }
    }
    return 1;
}

sub dump_lines {
    my ($self) = @_;
    my @out;
    for my $c ($self->sorted_controls) {
        my $s = sprintf('%03u:', $c->{addr});
        $s .= _print_node($c->{name}, $c->{unit}, 0);
        $s .= '.' . $c->{func} . '=';
        my $t = $c->{type} || 0;
        if ($t == SIOCTL_NUM || $t == SIOCTL_SW) {
            $s .= sprintf('0..%d (%u)', $c->{maxval} || 0, $c->{curval} || 0);
        } elsif ($t == SIOCTL_SEL) {
            $s .= _print_node($c->{name1}, $c->{unit1}, 0);
        } else {
            $s .= _print_node($c->{name1}, $c->{unit1}, 0);
            $s .= sprintf(':0..%d (%u)', $c->{maxval} || 0, $c->{curval} || 0);
        }
        $s .= _print_display($c->{display});
        push @out, $s;
    }
    return @out;
}

sub _match_par {
    my ($c, $name, $unit) = @_;
    return 0 unless $c->{name} eq $name;
    return 1 if $unit < 0;
    return $c->{unit} == $unit;
}

sub _match_ent {
    my ($c, $name, $unit) = @_;
    return 0 unless ($c->{name1} || '') eq $name;
    return 1 if $unit < 0;
    return ($c->{unit1} || 0) == $unit;
}

sub cmd {
    my ($self, $line) = @_;
    $line =~ s/^\s+|\s+$//g;
    return 0 unless length $line;
    my $group = '';
    if ($line =~ s{^([^/]+)/}{}) {
        $group = $1;
    }
    my ($node, $unit, $func, $rest);
    if ($line =~ /^([A-Za-z0-9_]+)(?:\[(\d+)\])?\.([A-Za-z0-9_]+)(.*)$/) {
        $node = $1;
        $unit = defined $2 ? int($2) : -1;
        $func = $3;
        $rest = $4;
    } else {
        $self->{err} = "bad command: $line";
        return 0;
    }
    my @hits = grep {
        ($_->{group} || '') eq $group
          && ($_->{func} || '') eq $func
          && ($_->{name} || '') eq $node
    } $self->sorted_controls;
    unless (@hits) {
        $self->{err} = "$node.$func: no such control";
        return 0;
    }
    return 1 if !defined $rest || $rest eq '';
    return 0 unless $rest =~ s/^=//;
    my $mode = 'set';
    if    ($rest =~ s/^\+//) { $mode = 'add'; }
    elsif ($rest =~ s/^-//)  { $mode = 'sub'; }
    elsif ($rest =~ s/^!//)  { $mode = 'toggle'; }

    my $type = $hits[0]{type} || 0;
    if ($type == SIOCTL_NUM || $type == SIOCTL_SW) {
        my $frac = 0;
        if ($mode ne 'toggle') {
            unless ($rest =~ /^([0-9.]+)/) {
                $self->{err} = "number expected near '$rest'";
                return 0;
            }
            $frac = $1 + 0;
        }
        for my $c (@hits) {
            next unless _match_par($c, $node, $unit);
            my $max = $c->{maxval} || 1;
            my $val;
            if ($mode eq 'toggle') {
                $val = $c->{curval} ? 0 : $max;
            } elsif ($mode eq 'add') {
                $val = ($c->{curval} || 0) + int($frac * $max + 0.5);
            } elsif ($mode eq 'sub') {
                $val = ($c->{curval} || 0) - int($frac * $max + 0.5);
            } else {
                $val = int($frac * $max + 0.5);
            }
            $val = 0   if $val < 0;
            $val = $max if $val > $max;
            $self->setval($c->{addr}, $val);
        }
        return 1;
    }

    if ($mode eq 'set') {
        for my $c (@hits) {
            next unless _match_par($c, $node, $unit);
            $self->setval($c->{addr}, 0);
        }
    }
    $rest =~ s/\([^)]*\)//g;
    for my $tok (split /,/, $rest) {
        next unless length $tok;
        my ($vname, $vunit, $frac) = ($tok, -1, 1);
        if ($tok =~ /^([A-Za-z0-9_]+)(?:\[(\d+)\])?(?::([0-9.]+))?$/) {
            $vname = $1;
            $vunit = defined $2 ? int($2) : -1;
            $frac  = defined $3 ? $3 + 0 : 1;
        }
        for my $c (@hits) {
            next unless _match_par($c, $node, $unit);
            next unless _match_ent($c, $vname, $vunit);
            my $max = $c->{maxval} || 1;
            my $val = int($frac * $max + 0.5);
            if ($mode eq 'toggle') {
                $val = $c->{curval} ? 0 : $max;
            } elsif ($mode eq 'add') {
                $val = ($c->{curval} || 0) + $val;
            } elsif ($mode eq 'sub') {
                $val = ($c->{curval} || 0) - $val;
            }
            $val = 0   if $val < 0;
            $val = $max if $val > $max;
            $self->setval($c->{addr}, $val);
        }
    }
    return 1;
}

sub _levels { $_[0] ? @{ $_[0]{levels} || [] } : () }
sub _mutes  { $_[0] ? @{ $_[0]{mutes}  || [] } : () }

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
            key => $key, group => $g, name => $n, levels => [], mutes => [],
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
    if (grep { ($_->{curval} || 0) > 0 } @lv) {
        $face->{saved} = [ map { $_->{curval} } @lv ];
        my $ok = 0;
        for my $c (@lv) { $ok++ if $self->setval($c->{addr}, 0); }
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

sub is_muted {
    my ($self, $face) = @_;
    return 0 unless $face;
    my @mutes = _mutes($face);
    if (@mutes) {
        for my $m (@mutes) {
            return 0 unless $m->{curval};
        }
        return @mutes ? 1 : 0;
    }
    my @lv = _levels($face) or return 0;
    for my $c (@lv) {
        return 0 if ($c->{curval} || 0) > 0;
    }
    return 1;
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
