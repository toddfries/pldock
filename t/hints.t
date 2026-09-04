#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Spec;

BEGIN {
	my $here = dirname(File::Spec->rel2abs($0));
	unshift @INC, File::Spec->catdir($here, '..', 'lib');
}

use Pldock;

# flags, input, initial_state, icon_pixmap, icon_window, icon_x, icon_y, icon_mask, window_group
my $icon = 0xa00010;
my $raw = pack('L*',
	Pldock::IconWindowHint | Pldock::StateHint,
	0, 0, 0, $icon, 0, 0, 0, 0,
);
my $h = Pldock::unpack_wm_hints($raw);
ok($h, 'unpacked');
is($h->{icon_window}, $icon, 'icon_window');
ok($h->{flags} & Pldock::IconWindowHint, 'IconWindowHint set');
is(Pldock::hints_icon_window($h), $icon, 'hints_icon_window');

my $plain = pack('L*', Pldock::InputHint, 1, 1, 0, 0, 0, 0, 0, 0);
my $p = Pldock::unpack_wm_hints($plain);
ok(!Pldock::hints_icon_window($p), 'no icon window without hint');

ok(!Pldock::unpack_wm_hints(undef), 'undef hints');
ok(!Pldock::hints_icon_window(undef), 'undef icon');

done_testing();
