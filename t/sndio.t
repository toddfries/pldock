#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Spec;
use IO::Socket;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

BEGIN {
    my $here = dirname(File::Spec->rel2abs($0));
    unshift @INC, File::Spec->catdir($here, '..', 'lib');
}

use Pldock::Sndio;

my $SIOCTL_NONE = Pldock::Sndio::SIOCTL_NONE;
my $SIOCTL_NUM  = Pldock::Sndio::SIOCTL_NUM;
my $SIOCTL_SW   = Pldock::Sndio::SIOCTL_SW;
my $SIOCTL_VEC  = Pldock::Sndio::SIOCTL_VEC;
my $SIOCTL_SEL  = Pldock::Sndio::SIOCTL_SEL;
my $AMSG_ACK    = Pldock::Sndio::AMSG_ACK;
my $AMSG_DATA   = Pldock::Sndio::AMSG_DATA;
my $AMSG_CTLSET = Pldock::Sndio::AMSG_CTLSET;
my $AMSG_CTLSYNC = Pldock::Sndio::AMSG_CTLSYNC;
my $AMSG_SIZE   = Pldock::Sndio::AMSG_SIZE;
my $DESC_SIZE   = Pldock::Sndio::DESC_SIZE;

sub ctl {
    my %c = @_;
    $c{type}    = $SIOCTL_NUM unless defined $c{type};
    $c{maxval}  = 127 unless defined $c{maxval};
    $c{curval}  = 0   unless defined $c{curval};
    $c{unit}    = -1  unless defined $c{unit};
    $c{unit1}   = -1  unless defined $c{unit1};
    $c{group}   = ''  unless defined $c{group};
    $c{name1}   = ''  unless defined $c{name1};
    $c{func}    = $c{func} || 'level';
    $c{display} = $c{display} || '';
    return \%c;
}

sub sio_with {
    my $s = Pldock::Sndio->new(who => 'sndioctl', opt => 'default');
    $s->{ctls}{ $_->{addr} } = $_ for @_;
    $s->{synced} = 1;
    return $s;
}

# same template _parse_desc uses today (BE u16/u32)
sub pack_desc {
    my ($c) = @_;
    my $u0 = $c->{unit}  // -1;
    my $u1 = $c->{unit1} // -1;
    $u0 += 65536 if $u0 < 0;
    $u1 += 65536 if $u1 < 0;
    return pack('Z16 n x2 Z16 n x2 Z16 Z16 C x n n n x16 Z32',
        $c->{name} // '', $u0,
        $c->{name1} // '', $u1,
        $c->{func} // '', $c->{group} // '',
        $c->{type} // $SIOCTL_NUM,
        $c->{addr} // 0,
        $c->{maxval} // 127,
        $c->{curval} // 0,
        $c->{display} // '',
    );
}

# ---------------------------------------------------------------------------
# constructor / paths / amsg header
# ---------------------------------------------------------------------------

{
    my $s = Pldock::Sndio->new;
    is($s->{who}, 'pldock', 'default who');
    is($s->{opt}, 'default', 'default opt');
    is($s->{unit}, 0, 'default unit');
    ok(!$s->synced, 'not synced at new');
    is($s->error, undef, 'no error at new');
}

{
    my $s = Pldock::Sndio->new(who => 'abcdefghijklmnop', opt => 'profile-name-too-long', unit => 3);
    is($s->{who}, 'abcdefghijkl', 'who truncated to 12');
    is($s->{opt}, 'profile-name', 'opt truncated to 12');
    my @p = $s->sockpaths;
    is($p[0], sprintf('/tmp/sndio-%u/sock3', $<), 'uid sock path');
    is($p[1], '/tmp/sndio/sock3', 'legacy sock path');
}

{
    my $m = Pldock::Sndio::_pack_amsg($AMSG_CTLSET, pack('n n', 7, 64));
    is(length($m), $AMSG_SIZE, 'amsg is 40 bytes');
    my ($cmd, $pad, $body) = unpack('NNa32', $m);
    is($cmd, $AMSG_CTLSET, 'cmd field (current BE N template)');
    is($pad, 0xffffffff, 'rsvd is 0xff as AMSG_INIT');
    my ($addr, $val) = unpack('n n', $body);
    is($addr, 7, 'ctlset addr');
    is($val, 64, 'ctlset val');
}

# ---------------------------------------------------------------------------
# _parse_desc / _ingest_desc / _ingest_msg
# ---------------------------------------------------------------------------

{
    my $blob = pack_desc(ctl(
        name => 'output', unit => 0, name1 => '', unit1 => -1,
        func => 'level', group => '', type => $SIOCTL_NUM,
        addr => 12, maxval => 127, curval => 64, display => 'dac',
    ));
    is(length($blob), $DESC_SIZE, 'desc is 128 bytes');
    my $c = Pldock::Sndio::_parse_desc($blob);
    ok($c, 'parse_desc');
    is($c->{name}, 'output', 'name0');
    is($c->{unit}, 0, 'unit0');
    is($c->{func}, 'level', 'func');
    is($c->{group}, '', 'group');
    is($c->{type}, $SIOCTL_NUM, 'type');
    is($c->{addr}, 12, 'addr');
    is($c->{maxval}, 127, 'maxval');
    is($c->{curval}, 64, 'curval');
    is($c->{display}, 'dac', 'display');
}

{
    my $s = Pldock::Sndio->new;
    my $c = ctl(addr => 3, name => 'input', func => 'level', type => $SIOCTL_NUM);
    $s->_ingest_desc($c);
    ok($s->{ctls}{3}, 'ingest keeps control');
    $s->_ingest_desc(ctl(addr => 3, type => $SIOCTL_NONE));
    ok(!$s->{ctls}{3}, 'SIOCTL_NONE deletes');
}

{
    my $s = sio_with(ctl(addr => 4, name => 'input', func => 'level', curval => 10, maxval => 127));
    my $body = pack('n n', 4, 99) . ("\xff" x 28);
    $s->_ingest_msg(pack('NNa32', $AMSG_CTLSET, 0xffffffff, $body));
    is($s->{ctls}{4}{curval}, 99, 'CTLSET updates curval');

    $s->_ingest_msg(pack('NNa32', $AMSG_CTLSYNC, 0xffffffff, "\xff" x 32));
    ok($s->synced, 'CTLSYNC sets synced');

    my $data = pack('N', 256) . ("\xff" x 28);
    $s->_ingest_msg(pack('NNa32', $AMSG_DATA, 0xffffffff, $data));
    ok($s->{in_data}, 'DATA enters desc stream');
    is($s->{data_left}, 256, 'DATA size');
}

# ---------------------------------------------------------------------------
# formatters: node / num / display / format_par / list / dump
# ---------------------------------------------------------------------------

is(Pldock::Sndio::_print_node('output', 0, 0), 'output[0]', 'node with unit');
is(Pldock::Sndio::_print_node('output', 0, 1), 'output', 'mono hides unit');
is(Pldock::Sndio::_print_node('output', -1, 0), 'output', 'unit -1 has no index');

is(Pldock::Sndio::_print_num(ctl(curval => 1, maxval => 1)), '1', 'sw prints int');
is(Pldock::Sndio::_print_num(ctl(curval => 64, maxval => 127)),
    sprintf('%.3f', 64/127), 'level as fraction');

is(Pldock::Sndio::_print_display('Built-in (dac)'), '(Built-in dac)',
    'display strips parens');
is(Pldock::Sndio::_print_display(''), '', 'empty display');

{
    my $s = Pldock::Sndio->new;
    my $line = $s->format_par(ctl(
        group => '', name => 'output', unit => -1, func => 'level',
        type => $SIOCTL_NUM, curval => 64, maxval => 127, display => 'hp',
    ), mono => 1);
    is($line, 'output.level=' . sprintf('%.3f', 64/127) . '(hp)',
        'NUM format_par');
}

{
    my $s = Pldock::Sndio->new;
    my $line = $s->format_par(ctl(
        group => 'app', name => 'mpv', unit => -1, func => 'mute',
        type => $SIOCTL_SW, curval => 1, maxval => 1,
    ), mono => 1);
    is($line, 'app/mpv.mute=1', 'grouped SW');
}

{
    my $s = Pldock::Sndio->new;
    my $line = $s->format_par(ctl(
        group => '', name => 'output', unit => -1, func => 'level',
        type => $SIOCTL_NUM, curval => 64, maxval => 127,
    ), nflag => 1);
    is($line, sprintf('%.3f', 64/127), '-n prints value only');
}

{
    my $s = sio_with(
        ctl(addr => 1, name => 'output', unit => 0, func => 'level',
            type => $SIOCTL_NUM, curval => 64, maxval => 127),
        ctl(addr => 2, name => 'output', unit => 1, func => 'level',
            type => $SIOCTL_NUM, curval => 64, maxval => 127),
    );
    my @m = $s->list_lines(members => 1);
    is(scalar @m, 3, 'members: group + two channels');
    like($m[0], qr/^output\.level=/, 'group line first');
    like($m[1], qr/^output\[0\]\.level=/, 'unit 0');
    like($m[2], qr/^output\[1\]\.level=/, 'unit 1');

    $s->{ctls}{2}{curval} = 32;
    my @split = $s->list_lines(members => 1);
    is(scalar @split, 3, 'unequal still prints group + members');
    like($split[0], qr/^output\.level=/, 'group line still a set-all command');
}

{
    my $s = sio_with(
        ctl(addr => 1, name => 'output', unit => 0, func => 'level',
            type => $SIOCTL_NUM, curval => 10, maxval => 127),
        ctl(addr => 2, name => 'output', unit => 1, func => 'level',
            type => $SIOCTL_NUM, curval => 10, maxval => 127),
    );
    with_send_stub($s, sub {
        my $o = shift;
        ok($o->cmd('output[0].level=1'), 'write unit 0');
        is($o->{ctls}{1}{curval}, 127, 'unit 0 max');
        is($o->{ctls}{2}{curval}, 10,  'unit 1 unchanged');
        ok($o->cmd('output.level=0'), 'write group');
        is($o->{ctls}{1}{curval}, 0, 'unit 0 zeroed');
        is($o->{ctls}{2}{curval}, 0, 'unit 1 zeroed');
    });
}
{
    my $s = sio_with(
        ctl(addr => 9, name => 'input', unit => 0, func => 'level',
            type => $SIOCTL_NUM, curval => 10, maxval => 127),
    );
    my ($d) = $s->dump_lines;
    is($d, '009:input[0].level=0..127 (10)', 'dump_lines -d shape');
}

{
    my $s = sio_with(
        ctl(addr => 20, name => 'server', func => 'device', type => $SIOCTL_SEL,
            name1 => 'rsnd', unit1 => 0, curval => 1, maxval => 1),
    );
    my ($d) = $s->dump_lines;
    is($d, '020:server.device=rsnd[0]', 'SEL dump uses node1');
}

# ---------------------------------------------------------------------------
# cmd parser (no real socket: stub _send)
# ---------------------------------------------------------------------------

sub with_send_stub {
    my ($s, $code) = @_;
    $s->{sock} = 1;
    no warnings 'redefine';
    local *Pldock::Sndio::_send = sub { 1 };
    $code->($s);
}

{
    my $s = sio_with(ctl(
        addr => 1, name => 'output', func => 'level',
        type => $SIOCTL_NUM, curval => 64, maxval => 127,
    ));
    with_send_stub($s, sub {
        my $o = shift;
        ok($o->cmd('output.level=1'), 'set absolute');
        is($o->{ctls}{1}{curval}, 127, 'frac 1 -> max');

        ok($o->cmd('output.level=0'), 'set zero');
        is($o->{ctls}{1}{curval}, 0, 'frac 0 -> 0');

        ok($o->cmd('output.level=+0.5'), 'add');
        ok($o->{ctls}{1}{curval} > 0, 'add moved up');

        ok($o->cmd('output.level=!'), 'toggle');
        is($o->{ctls}{1}{curval}, 0, 'toggle to 0 from nonzero');

        ok(!$o->cmd('nope.level=1'), 'missing control fails');
        like($o->error, qr/no such control/, 'error text');

        ok(!$o->cmd('!!!'), 'junk command fails');
    });
}

{
    my $s = sio_with(
        ctl(addr => 5, group => 'app', name => 'mpv', func => 'mute',
            type => $SIOCTL_SW, curval => 0, maxval => 1),
    );
    with_send_stub($s, sub {
        my $o = shift;
        ok($o->cmd('app/mpv.mute=1'), 'grouped set');
        is($o->{ctls}{5}{curval}, 1, 'mute on');
    });
}

# ---------------------------------------------------------------------------
# faces / mixer helpers
# ---------------------------------------------------------------------------

{
    my $s = sio_with(
        ctl(addr => 1, name => 'input',  func => 'level', curval => 32, maxval => 127),
        ctl(addr => 2, name => 'input',  func => 'mute',  type => $SIOCTL_SW, curval => 0, maxval => 1),
        ctl(addr => 3, name => 'output', func => 'level', curval => 64, maxval => 127),
        ctl(addr => 4, group => 'app', name => 'mpv', func => 'level', curval => 80, maxval => 127),
        ctl(addr => 5, name => 'output', func => 'noremap', curval => 1, maxval => 1),
    );
    my @f = $s->faces;
    is(scalar @f, 3, 'input, output, app/mpv');
    is($f[0]{key}, 'input', 'input first');
    is($f[1]{key}, 'output', 'output second');
    is($f[2]{key}, 'app/mpv', 'app after');

    ok(abs($s->frac($f[0]) - 32/127) < 1e-6, 'frac');
    ok(!$s->is_muted($f[0]), 'not muted');

    with_send_stub($s, sub {
        my $o = shift;
        ok($o->set_frac($f[1], 1), 'set_frac');
        is($o->{ctls}{3}{curval}, 127, 'frac 1');

        ok($o->apply_delta($f[1], -0.5), 'apply_delta');
        ok($o->{ctls}{3}{curval} < 127, 'delta down');

        ok($o->toggle_mute($f[0]), 'toggle mute switch');
        is($o->{ctls}{2}{curval}, 1, 'mute on');
        ok($o->is_muted($f[0]), 'is_muted after switch');
    });
}

# mute-by-zero when there is no mute control
{
    my $s = sio_with(ctl(addr => 8, name => 'output', func => 'level', curval => 40, maxval => 127));
    my ($f) = $s->faces;
    with_send_stub($s, sub {
        my $o = shift;
        ok($o->toggle_mute($f), 'soft mute');
        is($o->{ctls}{8}{curval}, 0, 'level zeroed');
        ok($o->is_muted($f), 'soft-muted');
        ok($o->toggle_mute($f), 'unmute restores');
        is($o->{ctls}{8}{curval}, 40, 'saved level restored');
    });
}

# ---------------------------------------------------------------------------
# poll: DATA blob + desc + CTLSYNC over a socketpair
# ---------------------------------------------------------------------------

{
    my ($w, $r);
    if (IO::Socket->can('socketpair')) {
        ($w, $r) = IO::Socket->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC);
    }
    ok($w && $r, 'socketpair') or do { diag("socketpair: $!"); goto AFTER_POLL; };

    $w->autoflush(1);
    $r->autoflush(1);

    my $s = Pldock::Sndio->new;
    $s->{sock} = $r;

    my $fl = fcntl($r, F_GETFL, 0);
    fcntl($r, F_SETFL, $fl | O_NONBLOCK) if defined $fl;

    my $desc = pack_desc(ctl(
        addr => 42, name => 'output', func => 'level',
        type => $SIOCTL_NUM, curval => 77, maxval => 127, unit => -1,
    ));
    my $data = Pldock::Sndio::_pack_amsg($AMSG_DATA, pack('N', $DESC_SIZE));
    my $sync = Pldock::Sndio::_pack_amsg($AMSG_CTLSYNC, '');
    syswrite($w, $data . $desc . $sync) or diag("write: $!");
    close $w;    # EOF if poll ever reads again

    my $n;
    {
        local $SIG{ALRM} = sub { die "poll timed out\n" };
        alarm 2;
        $n = eval { $s->poll };
        alarm 0;
    }
    ok(!$@, 'poll returned') or diag($@);
    ok(($n || 0) > 0, 'poll read bytes');
    ok($s->synced, 'poll saw CTLSYNC');
    ok($s->{ctls}{42}, 'poll ingested desc');
    is($s->{ctls}{42}{curval}, 77, 'desc curval') if $s->{ctls}{42};
    if ($s->{ctls}{42}) {
        is(($s->list_lines)[0],
            'output.level=' . sprintf('%.3f', 77/127),
            'list_lines after synthetic stream');
    }
    close $r;
}
AFTER_POLL:


# Optional live check. Not the piecemeal suite.
if ($ENV{PLDOCK_SNDIO_LIVE}) {
    my $s = Pldock::Sndio->new(who => 'sndioctl');
    my $ok;
    {
        local $SIG{ALRM} = sub { die "live connect timed out\n" };
        alarm 5;
        $ok = eval { $s->connect };
        alarm 0;
    }
    ok(!$@, 'live connect returned') or diag($@);
    ok($ok, 'live connect') or diag($s->error);
    if ($ok) {
        my @lines = $s->list_lines;
        ok(@lines, 'live list_lines nonempty')
          or diag('synced=' . ($s->synced ? 1 : 0)
            . ' ctls=' . scalar keys %{ $s->{ctls} });
        diag($_) for @lines[0 .. ($#lines > 4 ? 4 : $#lines)];
        $s->disconnect;
    }
}

done_testing();
