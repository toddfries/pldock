package Pldock;

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
use POSIX qw(_exit WNOHANG mkfifo setsid);
use Fcntl qw(O_RDWR O_NONBLOCK);
use Time::HiRes qw(time);
use File::Basename qw(dirname);
use File::Spec;

our $VERSION = '1.0';

# XWMHints.flags bits (X11/Xutil.h)
use constant InputHint        => (1 << 0);
use constant StateHint        => (1 << 1);
use constant IconPixmapHint   => (1 << 2);
use constant IconWindowHint   => (1 << 3);
use constant IconPositionHint => (1 << 4);
use constant IconMaskHint     => (1 << 5);
use constant WindowGroupHint  => (1 << 6);

use constant RESPAWN_MAX => 5;

# ---------------------------------------------------------------------------
# Pure helpers (tested without X)
# ---------------------------------------------------------------------------

sub parse_wm_class {
	my ($raw) = @_;
	return ('', '') unless defined $raw && length $raw;
	$raw =~ s/\0+\z//;
	my ($inst, $class) = split /\0/, $raw, 2;
	$inst  = '' unless defined $inst;
	$class = '' unless defined $class;
	return ($inst, $class);
}

sub unpack_wm_hints {
	my ($raw) = @_;
	return unless defined $raw && length($raw) >= 4;
	my @f = unpack('L*', $raw);
	return {
		flags         => $f[0] // 0,
		input         => $f[1] // 0,
		initial_state => $f[2] // 0,
		icon_pixmap   => $f[3] // 0,
		icon_window   => $f[4] // 0,
		icon_x        => $f[5] // 0,
		icon_y        => $f[6] // 0,
		icon_mask     => $f[7] // 0,
		window_group  => $f[8] // 0,
	};
}

sub hints_icon_window {
	my ($hints) = @_;
	return unless $hints && ($hints->{flags} & IconWindowHint);
	my $w = $hints->{icon_window} // 0;
	return $w if $w;
	return;
}

sub _basename {
	my ($s) = @_;
	return '' unless defined $s && length $s;
	$s =~ s{.*/}{};
	return $s;
}

sub name_matches {
	my ($got, $pat) = @_;
	return 0 unless defined $got && defined $pat && length $pat;
	return 1 if lc($got) eq lc($pat);
	# wmapm sets WM_CLASS to "/usr/local/bin/wmapm"
	my $gb = _basename($got);
	my $pb = _basename($pat);
	return 1 if length $gb && lc($gb) eq lc($pat);
	return 1 if length $gb && length $pb && lc($gb) eq lc($pb);
	return 0;
}

sub class_matches_slot {
	my ($inst, $class, $name, $slot) = @_;
	return 0 unless $slot && $slot->{match};
	for my $pat (@{ $slot->{match} }) {
		return 1 if name_matches($inst, $pat)
		         || name_matches($class, $pat)
		         || name_matches($name, $pat);
	}
	return 0;
}

# Count slots still waiting for a client. Call as a function so `&&` cannot
# steal grep's LIST (grep BLOCK @slots && expr  →  grep over "1").
sub any_unfilled {
	my ($slots) = @_;
	return 0 unless $slots && @$slots;
	return scalar grep { !$_->{swallowed} } @$slots;
}

sub builtin_apps {
	return (
		wmclock => {
			argv  => [ 'wmclock' ],
			match => [ 'wmclock' ],
			w     => 54,
			h     => 57,
		},
		wmapm => {
			argv  => [ 'wmapm' ],
			match => [ 'wmapm' ],
			w     => 54,
			h     => 57,
		},
		xload => {
			argv  => [ 'xload', '-nolabel', '-update', '1' ],
			match => [ 'xload', 'XLoad' ],
			w     => 120,
			h     => 57,
		},
		xconsole => {
			argv  => [ 'xconsole' ],
			match => [ 'xconsole', 'XConsole' ],
			w     => 200,
			h     => 96,
		},
	);
}

sub default_conf_text {
	return <<'CONF';
# Nested hbox (row) / vbox (column). Geometry is relative to an xrandr
# output (`screen primary`). stretch takes leftover on the parent main axis.

dock {
	pos     bottom-right
	screen  primary
	width   1/3
	height  auto
	gap     2

	vbox {
		hbox {
			tile wmclock
			tile wmapm
			tile xload stretch
		}
		tile xconsole stretch min=96
	}
}
CONF
}

sub default_slots {
	my $cfg = parse_conf_text(default_conf_text(), 'builtin');
	return flatten_tiles($cfg->{root});
}

# ---------------------------------------------------------------------------
# Config language
# ---------------------------------------------------------------------------

sub tokenize_conf {
	my ($s, $file) = @_;
	$file ||= 'conf';
	my @t;
	my $line = 1;
	pos($s) = 0;
	my $len = length($s);
	while (pos($s) < $len) {
		if ($s =~ /\G[ \t]+/gc) {
			next;
		}
		if ($s =~ /\G\r?\n/gc) {
			$line++;
			next;
		}
		if ($s =~ /\G#[^\n]*/gc) {
			next;
		}
		if ($s =~ /\G\{/gc) {
			push @t, [ '{', '{', $line ];
			next;
		}
		if ($s =~ /\G\}/gc) {
			push @t, [ '}', '}', $line ];
			next;
		}
		if ($s =~ /\G=/gc) {
			push @t, [ '=', '=', $line ];
			next;
		}
		if ($s =~ /\G"((?:\\.|[^"\\])*)"/gc) {
			my $str = $1;
			$str =~ s/\\(.)/$1/g;
			push @t, [ 'STRING', $str, $line ];
			next;
		}
		if ($s =~ /\G(\d+)\/(\d+)/gc) {
			push @t, [ 'FRAC', "$1/$2", $line ];
			next;
		}
		if ($s =~ /\G(\d+)x(\d+)/gc) {
			push @t, [ 'SIZE', "$1x$2", $line ];
			next;
		}
		if ($s =~ /\G(\d+\.\d+)/gc) {
			push @t, [ 'NUM', $1, $line ];
			next;
		}
		if ($s =~ /\G(\d+)/gc) {
			push @t, [ 'NUM', $1, $line ];
			next;
		}
		if ($s =~ /\G([A-Za-z_][A-Za-z0-9_,-]*)/gc) {
			push @t, [ 'WORD', $1, $line ];
			next;
		}
		my $ch = substr($s, pos($s), 1);
		die "pldock: $file:$line: unexpected '$ch'\n";
	}
	push @t, [ 'EOF', '', $line ];
	return \@t;
}

sub parse_conf_text {
	my ($text, $file) = @_;
	$file ||= 'conf';
	my $c = { toks => tokenize_conf($text, $file), i => 0, file => $file };
	my $cfg = _parse_dock($c);
	_expect($c, 'EOF');
	return $cfg;
}

sub _tok {
	my ($c) = @_;
	return $c->{toks}[ $c->{i} ];
}

sub _peek {
	my ($c) = @_;
	return _tok($c)->[0];
}

sub _val {
	my ($c) = @_;
	return _tok($c)->[1];
}

sub _tline {
	my ($c) = @_;
	return _tok($c)->[2];
}

sub _advance {
	my ($c) = @_;
	$c->{i}++;
}

sub _die {
	my ($c, $msg) = @_;
	die "pldock: $c->{file}:" . _tline($c) . ": $msg\n";
}

sub _expect {
	my ($c, $type) = @_;
	if (_peek($c) ne $type) {
		_die($c, "expected $type, got " . _peek($c));
	}
	my $v = _val($c);
	_advance($c);
	return $v;
}

sub _parse_dock {
	my ($c) = @_;
	if (_peek($c) ne 'WORD' || _val($c) ne 'dock') {
		_die($c, "expected 'dock'");
	}
	_advance($c);
	_expect($c, '{');
	my $cfg = {
		pos         => 'bottom-right',
		width       => '1/3',
		height      => 'auto',
		gap         => 2,
		override    => 0,
		height_auto => 1,
		screen      => 'primary',
		spawn       => 0,
	};
	my @kids;
	while (_peek($c) ne '}' && _peek($c) ne 'EOF') {
		if (_peek($c) eq 'WORD' && _is_item_kw(_val($c))) {
			push @kids, _parse_node($c);
		} else {
			_parse_attr($c, $cfg);
		}
	}
	_expect($c, '}');
	_die($c, "dock has no tiles") unless @kids;
	$cfg->{root} = @kids == 1 ? $kids[0]
	  : { type => 'vbox', kids => \@kids, stretch => 0, weight => 1 };
	$cfg->{height_auto} = !defined $cfg->{height}
	  || $cfg->{height} eq 'auto';
	return $cfg;
}

sub _parse_node {
	my ($c) = @_;
	_die($c, "expected tile, plugin, script, hbox, or vbox")
	  unless _peek($c) eq 'WORD';
	my $kw = _val($c);
	_advance($c);
	if ($kw eq 'hbox' || $kw eq 'vbox') {
		_expect($c, '{');
		my $node = { type => $kw, kids => [], stretch => 0, weight => 1 };
		while (_peek($c) ne '}' && _peek($c) ne 'EOF') {
			if (_peek($c) eq 'WORD' && _is_item_kw(_val($c))) {
				push @{ $node->{kids} }, _parse_node($c);
			} else {
				_parse_attr($c, $node);
			}
		}
		_expect($c, '}');
		_die($c, "$kw is empty") unless @{ $node->{kids} };
		return $node;
	}
	if ($kw eq 'plugin') {
		_die($c, "plugin needs a name") unless _peek($c) eq 'WORD';
		my $name = _val($c);
		_advance($c);
		my $node = {
			type      => 'plugin',
			plugin    => $name,
			id        => $name,
			w         => 120,
			h         => 57,
			content_w => 120,
			content_h => 57,
			stretch   => 0,
			weight    => 1,
			min       => 0,
			input     => 'disk',
		};
		while (_peek($c) eq 'WORD') {
			my $w = _val($c);
			last if _is_item_kw($w) || $w eq 'dock';
			_parse_attr($c, $node);
		}
		if ($node->{input}) {
			$node->{id} = $name . '-' . $node->{input};
		}
		return $node;
	}
	if ($kw eq 'script') {
		my $pt = _peek($c);
		_die($c, "script needs a command")
		  unless $pt eq 'STRING' || $pt eq 'WORD';
		my $cmd = _val($c);
		_advance($c);
		my $id = $cmd;
		$id =~ s/\W+/_/g;
		$id = 'script' unless length $id;
		my $node = {
			type      => 'script',
			plugin    => 'script',
			id        => "script-$id",
			cmd       => $cmd,
			freq      => 300,
			w         => 80,
			h         => 57,
			content_w => 80,
			content_h => 57,
			stretch   => 0,
			weight    => 1,
			min       => 0,
		};
		while (_peek($c) eq 'WORD') {
			my $w = _val($c);
			last if _is_item_kw($w) || $w eq 'dock';
			_parse_attr($c, $node);
		}
		return $node;
	}
	if ($kw eq 'tile') {
		_die($c, "tile needs a name") unless _peek($c) eq 'WORD';
		my $name = _val($c);
		_advance($c);
		my $node = _tile_from_name($name);
		while (_peek($c) eq 'WORD') {
			my $w = _val($c);
			last if _is_item_kw($w) || $w eq 'dock';
			_parse_attr($c, $node);
		}
		return $node;
	}
	_die($c, "unknown block '$kw'");
}

sub _is_item_kw {
	my ($w) = @_;
	return $w eq 'vbox' || $w eq 'hbox' || $w eq 'tile'
	    || $w eq 'plugin' || $w eq 'script';
}

sub _is_leaf {
	my ($node) = @_;
	my $t = $node->{type} || '';
	return $t eq 'tile' || $t eq 'plugin' || $t eq 'script';
}

sub _tile_from_name {
	my ($name) = @_;
	my %apps = builtin_apps();
	my $base = $apps{$name} || {
		argv  => [ $name ],
		match => [ $name ],
		w     => 64,
		h     => 64,
	};
	return {
		type      => 'tile',
		id        => $name,
		argv      => [ @{ $base->{argv} } ],
		match     => [ @{ $base->{match} } ],
		w         => $base->{w},
		h         => $base->{h},
		content_w => $base->{w},
		content_h => $base->{h},
		stretch   => 0,
		weight    => 1,
		min       => 0,
	};
}

sub _parse_attr {
	my ($c, $into) = @_;
	_die($c, "expected attribute") unless _peek($c) eq 'WORD';
	my $key = _val($c);
	_advance($c);
	if ($key eq 'stretch' || $key eq 'override' || $key eq 'spawn') {
		if (_peek($c) eq '=' || _peek($c) eq 'NUM') {
			_advance($c) if _peek($c) eq '=';
			my $v = _val($c);
			_advance($c);
			$into->{$key} = ($v eq '0' || $v eq 'off' || $v eq 'no') ? 0 : 1;
		} else {
			$into->{$key} = 1;
		}
		return;
	}
	if ($key eq 'managed') {
		$into->{override} = 0;
		return;
	}
	if (_peek($c) eq '=') {
		_advance($c);
	}
	my $type = _peek($c);
	if ($type eq 'EOF' || $type eq '{' || $type eq '}') {
		_die($c, "attribute $key needs a value");
	}
	# another keyword starting a child — missing value
	if ($type eq 'WORD' && _is_item_kw(_val($c))) {
		_die($c, "attribute $key needs a value");
	}
	my $val = _val($c);
	_advance($c);
	if ($key eq 'cmd') {
		$into->{argv} = [ _split_cmd($val) ];
	} elsif ($key eq 'match') {
		$into->{match} = [ grep { length } split /,/, $val ];
	} elsif ($key eq 'min') {
		$into->{min} = 0 + $val;
	} elsif ($key eq 'freq' || $key eq 'refresh') {
		# refresh is an old name for freq (script tiles).
		my $f = $val;
		if ($f =~ /^(\d+)\/(\d+)$/ && $2) {
			$f = $1 / $2;
		}
		$into->{freq} = 0 + $f;
		$into->{freq} = 0.05 if $into->{freq} && $into->{freq} < 0.05;
	} elsif ($key eq 'weight') {
		$into->{weight} = 0 + $val;
		$into->{weight} = 1 if $into->{weight} < 1;
	} elsif ($key eq 'gap') {
		$into->{gap} = 0 + $val;
	} elsif ($key eq 'size') {
		if ($val =~ /^(\d+)x(\d+)$/) {
			$into->{w} = 0 + $1;
			$into->{h} = 0 + $2;
			$into->{content_w} = $into->{w};
			$into->{content_h} = $into->{h};
			$into->{size_locked} = 1;
		} else {
			_die($c, "size wants WxH");
		}
	} elsif ($key eq 'pos' || $key eq 'screen') {
		$into->{$key} = $val;
	} elsif ($key eq 'width' || $key eq 'height') {
		$into->{$key} = $val;
		# Pixel size on a leaf (tile wmclock width=56). Fractions
		# stay as specs for the dock.
		if ($val =~ /^\d+$/) {
			if ($key eq 'width') {
				$into->{w}         = 0 + $val;
				$into->{content_w} = 0 + $val;
			} else {
				$into->{h}         = 0 + $val;
				$into->{content_h} = 0 + $val;
			}
			$into->{size_locked} = 1;
		}
	} else {
		$into->{$key} = $val;
	}
}

sub _split_cmd {
	my ($s) = @_;
	my @out;
	while ($s =~ /\S/) {
		if ($s =~ s/^\s*"((?:\\.|[^"\\])*)"//) {
			my $t = $1;
			$t =~ s/\\(.)/$1/g;
			push @out, $t;
		} elsif ($s =~ s/^\s*(\S+)//) {
			push @out, $1;
		} else {
			last;
		}
	}
	return @out;
}

sub parse_dim {
	my ($spec, $full) = @_;
	return unless defined $spec && length $spec;
	return if $spec eq 'auto';
	$full ||= 0;
	if ($spec =~ /^(\d+)\/(\d+)$/) {
		return 0 if $2 == 0;
		return int($full * $1 / $2);
	}
	if ($spec =~ /^(\d+(?:\.\d+)?)%$/) {
		return int($full * $1 / 100);
	}
	if ($spec =~ /^\d+$/) {
		return 0 + $spec;
	}
	return;
}

sub flatten_tiles {
	my ($node) = @_;
	return () unless $node;
	if (_is_leaf($node)) {
		return $node;
	}
	my @out;
	for my $k (@{ $node->{kids} || [] }) {
		push @out, flatten_tiles($k);
	}
	return @out;
}

sub prune_tree {
	my ($node, $skip) = @_;
	return unless $node;
	$skip ||= {};
	if (_is_leaf($node)) {
		return $skip->{ $node->{id} } ? () : $node;
	}
	my @k;
	for my $ch (@{ $node->{kids} || [] }) {
		push @k, prune_tree($ch, $skip);
	}
	return unless @k;
	$node->{kids} = \@k;
	return $node;
}

sub preferred_size {
	my ($node, $gap) = @_;
	$gap = 2 unless defined $gap;
	return (0, 0) unless $node;
	if (_is_leaf($node)) {
		my $w = $node->{content_w} || $node->{w} || 0;
		my $h = $node->{content_h} || $node->{h} || 0;
		if ($node->{stretch} && $node->{min}) {
			$w = $node->{min} if $w < $node->{min};
			$h = $node->{min} if $h < $node->{min};
		}
		return ($w, $h);
	}
	my $n = @{ $node->{kids} || [] };
	return (0, 0) unless $n;
	my ($acc_w, $acc_h, $max_w, $max_h) = (0, 0, 0, 0);
	for my $k (@{ $node->{kids} }) {
		my ($cw, $ch) = preferred_size($k, $gap);
		$max_w = $cw if $cw > $max_w;
		$max_h = $ch if $ch > $max_h;
		$acc_w += $cw;
		$acc_h += $ch;
	}
	my $g = $n > 1 ? ($n - 1) * $gap : 0;
	if ($node->{type} eq 'hbox') {
		return ($acc_w + $g, $max_h);
	}
	return ($max_w, $acc_h + $g);
}

# Flex on the parent's main axis only. A horizontally stretching xload
# must not make its hbox eat leftover height in a vbox.
sub _node_flex {
	my ($node, $parent_is_hbox) = @_;
	return 0 unless $node;
	if (_is_leaf($node)) {
		return $node->{stretch} ? 1 : 0;
	}
	return 1 if $node->{stretch};
	my $is_hbox = ($node->{type} || '') eq 'hbox';
	return 0 unless ($parent_is_hbox && $is_hbox)
	  || (!$parent_is_hbox && !$is_hbox);
	for my $k (@{ $node->{kids} || [] }) {
		return 1 if _node_flex($k, $is_hbox);
	}
	return 0;
}

# Lay out $node into the cell (x,y,w,h). Tile nodes get x,y,w,h window rects.
sub layout_tree {
	my ($node, $w, $h, $gap) = @_;
	$gap = 2 unless defined $gap;
	return unless $node && $w > 0 && $h > 0;
	_layout_node($node, 0, 0, $w, $h, $gap, 0);
}

sub _layout_node {
	my ($node, $x, $y, $w, $h, $gap, $in_hbox) = @_;
	$w = 1 if $w < 1;
	$h = 1 if $h < 1;
	if (_is_leaf($node)) {
		if ($node->{stretch}) {
			$node->{x} = $x;
			$node->{y} = $y;
			$node->{w} = $w;
			$node->{h} = $h;
			$node->{slot_w} = $w;
			$node->{slot_h} = $h;
		} else {
			# Pack against the start of the cell on the parent's
			# main axis (left in an hbox, top in a vbox). Centering
			# a 54px dockapp in a wide cell was the gap after the
			# first fixed item.
			my $tw = $node->{content_w} || $node->{w} || 1;
			my $th = $node->{content_h} || $node->{h} || 1;
			$tw = $w if $tw > $w;
			$th = $h if $th > $h;
			if ($in_hbox) {
				$node->{x} = $x;
				$node->{y} = $y + int(($h - $th) / 2);
			} else {
				$node->{x} = $x + int(($w - $tw) / 2);
				$node->{y} = $y;
			}
			$node->{w} = $tw;
			$node->{h} = $th;
			$node->{slot_w} = $tw;
			$node->{slot_h} = $th;
		}
		return;
	}
	my @kids = @{ $node->{kids} || [] };
	return unless @kids;
	my $hbox = ($node->{type} || '') eq 'hbox';
	my $main = $hbox ? $w : $h;
	my $ngap = @kids > 1 ? $gap * (@kids - 1) : 0;
	my @flex;
	my $fixed = 0;
	my $fsum = 0;
	for my $i (0 .. $#kids) {
		my $k = $kids[$i];
		my ($pw, $ph) = preferred_size($k, $gap);
		my $pref = $hbox ? $pw : $ph;
		if (_node_flex($k, $hbox)) {
			my $min = $k->{min} || 0;
			$flex[$i] = { flex => ($k->{weight} || 1), min => $min };
			$fsum += $k->{weight} || 1;
		} else {
			$flex[$i] = { flex => 0, min => $pref, size => $pref };
			$fixed += $pref;
		}
	}
	my $left = $main - $fixed - $ngap;
	$left = 0 if $left < 0;
	my @sz;
	if ($fsum) {
		my $used = 0;
		my $last;
		for my $i (0 .. $#kids) {
			next unless $flex[$i]{flex};
			$last = $i;
		}
		for my $i (0 .. $#kids) {
			if (!$flex[$i]{flex}) {
				$sz[$i] = $flex[$i]{size};
				next;
			}
			my $got = int($left * $flex[$i]{flex} / $fsum);
			$got = $flex[$i]{min} if $got < $flex[$i]{min};
			$sz[$i] = $got;
			$used += $got unless $i == $last;
		}
		if (defined $last) {
			my $rest = $left - $used;
			$rest = $flex[$last]{min} if $rest < $flex[$last]{min};
			$sz[$last] = $rest;
		}
	} else {
		for my $i (0 .. $#kids) {
			$sz[$i] = $flex[$i]{size};
		}
	}
	my $cur = $hbox ? $x : $y;
	for my $i (0 .. $#kids) {
		my $sz = $sz[$i] || 0;
		$sz = 0 if $sz < 0;
		if ($hbox) {
			_layout_node($kids[$i], $cur, $y, $sz, $h, $gap, 1);
		} else {
			_layout_node($kids[$i], $x, $cur, $w, $sz, $gap, 0);
		}
		$cur += $sz + $gap;
	}
}

# xrandr(1) connected-output lines → list of
# { name, primary, connected, x, y, w, h }
sub parse_xrandr {
	my ($text) = @_;
	my @out;
	return @out unless defined $text;
	for my $line (split /\n/, $text) {
		next unless $line =~ /^(\S+)\s+connected\b/;
		my $name = $1;
		my $primary = $line =~ /\sprimary\s/ ? 1 : 0;
		next unless $line =~ /(\d+)x(\d+)\+(\d+)\+(\d+)/;
		push @out, {
			name      => $name,
			primary   => $primary,
			connected => 1,
			w         => 0 + $1,
			h         => 0 + $2,
			x         => 0 + $3,
			y         => 0 + $4,
		};
	}
	return @out;
}

# $spec: undef/''/'primary', output name, index, left/right
sub pick_output {
	my ($outputs, $spec) = @_;
	return unless $outputs && @$outputs;
	$spec = '' unless defined $spec;
	$spec =~ s/^\s+|\s+$//g;
	$spec = '' if lc($spec) eq 'primary';
	if ($spec eq '') {
		for my $o (@$outputs) {
			return $o if $o->{primary};
		}
		return $outputs->[0];
	}
	if ($spec =~ /^\d+$/) {
		return $outputs->[$spec] if $spec <= $#$outputs;
		return;
	}
	my $lc = lc $spec;
	if ($lc eq 'left') {
		return (sort { $a->{x} <=> $b->{x} || $a->{y} <=> $b->{y} } @$outputs)[0];
	}
	if ($lc eq 'right') {
		return (sort { $b->{x} <=> $a->{x} || $a->{y} <=> $b->{y} } @$outputs)[0];
	}
	if ($lc eq 'top') {
		return (sort { $a->{y} <=> $b->{y} || $a->{x} <=> $b->{x} } @$outputs)[0];
	}
	if ($lc eq 'bottom') {
		return (sort { $b->{y} <=> $a->{y} || $a->{x} <=> $b->{x} } @$outputs)[0];
	}
	for my $o (@$outputs) {
		return $o if lc($o->{name} || '') eq $lc;
	}
	return;
}

sub read_xrandr_text {
	for my $cmd ('xrandr', '/usr/X11R6/bin/xrandr') {
		my $text = `$cmd 2>/dev/null`;
		return $text if defined $text && $text =~ /\bconnected\b/;
	}
	return '';
}

# Runtime: xrandr outputs, or a single fake screen from $fallback.
sub query_outputs {
	my ($fallback) = @_;
	my @out = parse_xrandr(read_xrandr_text());
	return @out if @out;
	$fallback ||= {};
	return ({
		name      => 'default',
		primary   => 1,
		connected => 1,
		x         => 0,
		y         => 0,
		w         => $fallback->{w} || $fallback->{width} || 0,
		h         => $fallback->{h} || $fallback->{height} || 0,
	});
}

# $cfg, $root_w, $root_h
# $cfg, { x, y, w, h, name }
sub dock_geometry {
	my ($cfg, $a, $b) = @_;
	my ($ox, $oy, $ow, $oh) = (0, 0, 0, 0);
	if (ref $a eq 'HASH') {
		$ox = $a->{x} || 0;
		$oy = $a->{y} || 0;
		$ow = $a->{w} || $a->{width} || 0;
		$oh = $a->{h} || $a->{height} || 0;
	} else {
		$ow = $a || 0;
		$oh = $b || 0;
	}
	my $gap = defined $cfg->{gap} ? $cfg->{gap} : 2;
	my ($pw, $ph) = preferred_size($cfg->{root}, $gap);
	my $w = parse_dim($cfg->{width}, $ow);
	$w = $pw if !defined $w;
	$w = $ow if $ow && $w > $ow;
	$w = 1 if !$w || $w < 1;
	my $h;
	if ($cfg->{height_auto} || !defined $cfg->{height} || $cfg->{height} eq 'auto') {
		$h = $ph;
	} else {
		$h = parse_dim($cfg->{height}, $oh);
	}
	$h = $ph if !defined $h;
	$h = $oh if $oh && $h > $oh;
	$h = 1 if !$h || $h < 1;
	my $pos = $cfg->{pos} || 'bottom-right';
	my $x = $ox;
	my $y = $oy;
	if ($pos eq 'bottom-right' || $pos eq 'right-bottom' || $pos eq 'right') {
		$x = $ox + $ow - $w;
		$y = $oy + $oh - $h;
	} elsif ($pos eq 'bottom-left' || $pos eq 'bottom') {
		$x = $ox;
		$y = $oy + $oh - $h;
	} elsif ($pos eq 'top-right') {
		$x = $ox + $ow - $w;
		$y = $oy;
	} else {
		$x = $ox;
		$y = $oy;
	}
	$x = $ox if $x < $ox;
	$y = $oy if $y < $oy;
	return {
		x    => $x,
		y    => $y,
		w    => $w,
		h    => $h,
		gap  => $gap,
		pos  => $pos,
	};
}

sub find_conf_path {
	my ($explicit) = @_;
	if (defined $explicit && length $explicit) {
		return $explicit;
	}
	return $ENV{PLDOCK_CONF} if defined $ENV{PLDOCK_CONF} && length $ENV{PLDOCK_CONF};
	my $home = $ENV{HOME} // '';
	my $p = File::Spec->catfile($home, '.config', 'pldock', 'pldock.conf');
	return $p if $p && -f $p;
	return;
}

sub ctl_path {
	my $home = $ENV{HOME} // '';
	return File::Spec->catfile($home, '.config', 'pldock', 'ctl');
}

sub conf_dir {
	my $home = $ENV{HOME} // '';
	return File::Spec->catdir($home, '.config', 'pldock');
}

my $_CTL_PATH;

sub _ctl_open {
	my ($st) = @_;
	my $dir  = conf_dir();
	my $path = ctl_path();
	if ($dir && !-d $dir) {
		require File::Path;
		eval { File::Path::make_path($dir, { mode => 0700 }) };
		if ($@ || !-d $dir) {
			_log('err', "mkdir $dir: $!");
			return;
		}
	}
	if (-e $path && !-p $path) {
		_log('err', "$path exists and is not a fifo");
		return;
	}
	unless (-p $path) {
		unless (mkfifo($path, 0600)) {
			_log('err', "mkfifo $path: $!");
			return;
		}
	}
	my $fh;
	unless (sysopen($fh, $path, O_RDWR | O_NONBLOCK)) {
		_log('err', "open $path: $!");
		return;
	}
	$st->{ctl_path} = $path;
	$st->{ctl_fh}   = $fh;
	$st->{ctl_fd}   = fileno($fh);
	$st->{ctl_buf}  = '';
	$_CTL_PATH      = $path;
}

sub _ctl_close {
	my ($st) = @_;
	close $st->{ctl_fh} if $st->{ctl_fh};
	$st->{ctl_fh}  = undef;
	$st->{ctl_fd}  = undef;
	$st->{ctl_buf} = '';
	my $path = $st->{ctl_path} || $_CTL_PATH;
	unlink $path if $path && -p $path;
	$st->{ctl_path} = undef;
	$_CTL_PATH      = undef;
}

sub _ctl_cmd {
	my ($st, $line) = @_;
	$line = '' unless defined $line;
	$line =~ s/\r$//;
	$line =~ s/^\s+|\s+$//g;
	return unless length $line;
	my $cmd = lc $line;
	if ($cmd eq 'exit' || $cmd eq 'quit') {
		$st->{quit} = 1;
		return;
	}
	if ($cmd eq 'reload' || $cmd eq 'hup') {
		$st->{hup} = 1;
		return;
	}
	if ($cmd eq 'restart') {
		$st->{restart} = 1;
		$st->{quit}    = 1;
		return;
	}
}

sub _ctl_read {
	my ($st) = @_;
	my $fh = $st->{ctl_fh} or return;
	my $n = sysread($fh, my $chunk, 4096);
	return unless defined $n && $n > 0;
	$st->{ctl_buf} .= $chunk;
	while ($st->{ctl_buf} =~ s/\A([^\n]*)\n//) {
		_ctl_cmd($st, $1);
	}
}

END {
	unlink $_CTL_PATH if $_CTL_PATH && -p $_CTL_PATH;
}


sub load_conf {
	my ($path) = @_;
	if (!defined $path || !length $path) {
		return parse_conf_text(default_conf_text(), 'builtin');
	}
	open my $fh, '<', $path or die "pldock: cannot read $path: $!\n";
	local $/;
	my $text = <$fh> // '';
	close $fh;
	return parse_conf_text($text, $path);
}

sub parse_cli_argv {
	my (@argv) = @_;
	my %opt = (
		pos      => undef,
		height   => undef,
		override => 0,
		gap      => undef,
		conf     => undef,
		screen   => undef,
		spawn    => 0,
		verbose  => 0,
		debug    => 0,
		want_3d  => 0,
		managed  => 0,
		skip     => {},
		_help    => 0,
	);
	while (@argv) {
		my $a = shift @argv;
		if ($a eq '-h' || $a eq '-help' || $a eq '--help') {
			$opt{_help} = 1;
		} elsif ($a eq '-top') {
			$opt{pos} = 'top-right';
		} elsif ($a eq '-bottom') {
			$opt{pos} = 'bottom-right';
		} elsif ($a eq '-pos') {
			my $p = shift @argv;
			die "pldock: -pos needs an argument\n" unless defined $p;
			$opt{pos} = $p;
		} elsif ($a eq '-c') {
			my $p = shift @argv;
			die "pldock: -c needs a file\n" unless defined $p;
			$opt{conf} = $p;
		} elsif ($a eq '-screen') {
			my $p = shift @argv;
			die "pldock: -screen needs an argument\n" unless defined $p;
			$opt{screen} = $p;
		} elsif ($a eq '-spawn') {
			$opt{spawn} = 1;
		} elsif ($a eq '-3d' || $a eq '--3d') {
			$opt{want_3d} = 1;
		} elsif ($a eq '-d' || $a eq '-debug' || $a eq '-foreground') {
			$opt{debug} = 1;
		} elsif ($a eq '-v' || $a eq '-verbose') {
			$opt{verbose} = 1;
		} elsif ($a eq '-managed') {
			$opt{managed} = 1;
			$opt{override} = 0;
		} elsif ($a eq '-override') {
			$opt{override} = 1;
		} elsif ($a eq '-height') {
			my $n = shift @argv;
			die "pldock: -height needs an argument\n" unless defined $n;
			$opt{height} = $n;
		} elsif ($a eq '-gap') {
			my $n = shift @argv;
			die "pldock: -gap needs an argument\n" unless defined $n;
			$opt{gap} = 0 + $n;
		} elsif ($a eq '-no-clock' || $a eq '-no-wmclock') {
			$opt{skip}{wmclock} = 1;
		} elsif ($a eq '-no-apm' || $a eq '-no-wmapm') {
			$opt{skip}{wmapm} = 1;
		} elsif ($a eq '-no-load' || $a eq '-no-xload') {
			$opt{skip}{xload} = 1;
		} elsif ($a eq '-no-console' || $a eq '-no-xconsole') {
			$opt{skip}{xconsole} = 1;
		} else {
			die "pldock: unknown option $a\n";
		}
	}
	return %opt;
}

sub print_cli_usage {
	print STDERR <<'USAGE';
usage: pldock [options]

Swallow existing X clients into one rectangle (no fork unless -spawn).
Layout comes from a config file (nested hbox/vbox). Geometry is relative
to an xrandr output (`screen primary`, `HDMI-1`, `right`, …). Ctrl-C
spits windows back to the root; SIGHUP reloads the config the same way.

options:
  -c FILE             config file (else ~/.config/pldock/pldock.conf,
                      or the built-in default)
  -screen NAME        xrandr output: primary, eDP-1, HDMI-1, left, right, 0
  -pos PLACE          top-left, top-right, bottom-left, bottom-right
  -top                -pos top-right
  -bottom             -pos bottom-right
  -height N           dock height in pixels (default: auto from tiles)
  -gap N              pixels between tiles
  -override           override-redirect (cwm cannot select the dock)
  -managed            let the WM place/select the dock (default)
  -spawn              fork/exec tiles that are not already mapped
  -3d, --3d           OpenGL cube spin on xloadio < > (cubetest / SDL::OpenGL)
  -d, -debug          stay in the foreground, log to stderr (not syslog)
  -v, -verbose        log screen pick and each ingest attempt by name
  -no-clock           do not swallow wmclock
  -no-apm             do not swallow wmapm
  -no-load            do not swallow xload
  -no-console         do not swallow xconsole
  -h, -help           this help

cwm: add `ignore pldock` (and optionally wmclock / wmapm) to ~/.cwmrc.
USAGE
}

our $RESTART_PROG;
our @RESTART_ARGV;
our $LOG_SYSLOG = 0;

sub _log {
	my ($pri, $msg) = @_;
	$msg = '' unless defined $msg;
	$msg =~ s/\n+\z//;
	$msg =~ s/^pldock:\s*//;
	return unless length $msg;
	if ($LOG_SYSLOG) {
		eval {
			require Sys::Syslog;
			Sys::Syslog::syslog(
				($pri eq 'err' ? 'err' : $pri eq 'debug' ? 'debug' : 'info'),
				'%s', $msg
			);
		};
	} else {
		print STDERR "pldock: $msg\n";
	}
}

sub _log_init {
	my ($syslog) = @_;
	$LOG_SYSLOG = $syslog ? 1 : 0;
	if ($LOG_SYSLOG) {
		require Sys::Syslog;
		Sys::Syslog::openlog('pldock', 'pid,ndelay,nowait', 'daemon');
	}
}

sub _daemonize {
	my $pid = fork;
	die "pldock: fork: $!\n" unless defined $pid;
	_exit(0) if $pid;
	setsid() or die "pldock: setsid: $!\n";
	chdir '/' or die "pldock: chdir: $!\n";
	open STDIN,  '<', '/dev/null' or die "pldock: stdin: $!\n";
	open STDOUT, '>', '/dev/null' or die "pldock: stdout: $!\n";
	open STDERR, '>', '/dev/null' or die "pldock: stderr: $!\n";
}

sub run_cli {
	my (@argv) = @_;
	$RESTART_PROG = File::Spec->rel2abs($0);
	@RESTART_ARGV = @argv;
	my %opt = eval { parse_cli_argv(@argv) };
	if ($@) {
		print STDERR $@;
		print_cli_usage();
		return 2;
	}
	if ($opt{_help}) {
		print_cli_usage();
		return 2;
	}
	if (!defined $ENV{DISPLAY} || $ENV{DISPLAY} eq '') {
		print STDERR "pldock: DISPLAY is unset\n";
		return 1;
	}
	if ($opt{debug}) {
		_log_init(0);
	} else {
		_daemonize();
		_log_init(1);
	}
	return run(%opt);
}

# ---------------------------------------------------------------------------
# X11 dock
# ---------------------------------------------------------------------------

sub run {
	my (%opt) = @_ == 1 && ref $_[0] eq 'HASH' ? %{ $_[0] } : @_;

	if (!defined $ENV{DISPLAY} || $ENV{DISPLAY} eq '') {
		_log('err', "DISPLAY is unset");
		return 1;
	}

	require X11::Protocol;

	my $X = X11::Protocol->new();
	$X->event_handler('queue');
	$X->{'error_handler'} = sub {
		my ($self, $data) = @_;
		my ($type) = unpack("xCxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", $data);
		my $name = $self->interp('Error', $type);
		return if $name eq 'Window' || $name eq 'Pixmap'
		       || $name eq 'Drawable' || $name eq 'Match'
		       || $name eq 'Value' || $name eq 'Atom';
		die $self->format_error_msg($data);
	};

	my $root = $X->root;
	my %state = (
		X        => $X,
		root     => $root,
		depth    => $X->root_depth,
		black    => $X->black_pixel,
		opt      => \%opt,
		quit     => 0,
		hup      => 0,
		reap     => 0,
		ours     => {},
		by_win   => {},
		plugin_win => {},
		slots    => [],
		plugin_tick => 0,
		xfd      => fileno($X->connection->fh),
		WM_NAME  => $X->atom('WM_NAME'),
		WM_CLASS => $X->atom('WM_CLASS'),
		WM_HINTS => $X->atom('WM_HINTS'),
		WM_PROTO => $X->atom('WM_PROTOCOLS'),
		WM_DEL   => $X->atom('WM_DELETE_WINDOW'),
		STRING   => $X->atom('STRING'),
		ATOM     => $X->atom('ATOM'),
		NET_TYPE => $X->atom('_NET_WM_WINDOW_TYPE'),
		NET_DOCK => $X->atom('_NET_WM_WINDOW_TYPE_DOCK'),
		NET_STRUT => $X->atom('_NET_WM_STRUT_PARTIAL'),
		verbose  => $opt{verbose} ? 1 : 0,
		want_3d  => $opt{want_3d} ? 1 : 0,
	);

	$X->ChangeWindowAttributes(
		$root,
		event_mask => $X->pack_event_mask(qw(SubstructureNotify)),
	);

	$SIG{INT}  = sub { $state{quit} = 1 };
	$SIG{TERM} = sub { $state{quit} = 1 };
	$SIG{HUP}  = sub { $state{hup}  = 1 };
	$SIG{PIPE} = 'IGNORE';
	$SIG{CHLD} = sub { $state{reap} = 1 };

	_ctl_open(\%state);

	while (!$state{quit}) {
		eval { _arm(\%state) };
		if ($@) {
			_log('err', $@);
			if ($state{cfg}) {
				# SIGHUP re-read failed: put the last good layout back.
				eval { _create_session(\%state, $state{cfg}) };
			}
			if ($@ || !$state{dock}) {
				_disarm(\%state);
				_ctl_close(\%state);
				return 1;
			}
		}

		my $fd = $state{xfd};
	  EVENT:
		while (!$state{quit} && !$state{hup}) {
			while (my %ev = $X->dequeue_event) {
				_handle_event(\%state, \%ev);
				last EVENT if $state{quit} || $state{hup};
			}

			if ($state{reap}) {
				$state{reap} = 0;
				_reap(\%state);
				_spawn_missing(\%state) if $state{spawn};
			}

			if (any_unfilled($state{slots}) && time() < ($state{scan_until} || 0)
			    && time() - ($state{last_scan} || 0) >= 1) {
				$state{last_scan} = time();
				_scan_for_clients(\%state);
			}

			my $spinning = grep {
				$_->{is_plugin} && $_->{obj}
				  && $_->{obj}->can('is_spinning')
				  && $_->{obj}->is_spinning
			} @{ $state{slots} || [] };
			my $tick = $spinning ? 0.05 : 0.25;
			if (time() - ($state{plugin_tick} || 0) >= $tick) {
				$state{plugin_tick} = time();
				_plugin_tick(\%state);
			}

			my $rin = "";
			vec($rin, $fd, 1) = 1;
			my $cfd = $state{ctl_fd};
			vec($rin, $cfd, 1) = 1 if defined $cfd;
			my $n = select(my $rout = $rin, undef, undef, $tick);
			if ($n) {
				$X->handle_input if vec($rout, $fd, 1);
				_ctl_read(\%state)
				  if defined $cfd && vec($rout, $cfd, 1);
			}
		}

		_disarm(\%state);
		last if $state{quit};
		$state{hup} = 0;
	}
	_disarm(\%state);
	if ($state{restart}) {
    		my $X = $state{X};
    		eval { $X->closedown } if $X;
    		$state{X} = undef;
	
    		_ctl_close(\%state);    # close + unlink fifo
	
    		my $prog = $Pldock::RESTART_PROG || File::Spec->rel2abs($0);
    		my @args = @Pldock::RESTART_ARGV;
	
    		exec $prog, @args
        		or exec $^X, $prog, @args
        		or do {
            			_log('err', "exec $prog: $!");
            			POSIX::_exit(1);
        		};
	}

	_ctl_close(\%state);
	return 0;
}

sub _apply_cli_cfg {
	my ($cfg, $opt) = @_;
	$opt ||= {};
	$cfg->{pos} = $opt->{pos} if defined $opt->{pos} && length $opt->{pos};
	$cfg->{gap} = $opt->{gap} if defined $opt->{gap};
	$cfg->{screen} = $opt->{screen}
	  if defined $opt->{screen} && length $opt->{screen};
	if (defined $opt->{height} && length $opt->{height}) {
		$cfg->{height} = $opt->{height};
		$cfg->{height_auto} = 0;
	}
	$cfg->{override} = 0 if $opt->{managed};
	$cfg->{override} = 1 if $opt->{override};
	$cfg->{spawn} = 1 if $opt->{spawn};
	$cfg->{want_3d} = 1 if $opt->{want_3d};
	if ($opt->{skip} && %{ $opt->{skip} }) {
		$cfg->{root} = prune_tree($cfg->{root}, $opt->{skip});
	}
	return $cfg;
}

sub _arm {
	my ($st) = @_;
	my $opt = $st->{opt} || {};
	my $path = find_conf_path($opt->{conf});
	if (defined $opt->{conf} && length $opt->{conf} && !-f $opt->{conf}) {
		die "pldock: cannot read $opt->{conf}: $!\n";
	}
	my $cfg = load_conf($path);
	_apply_cli_cfg($cfg, $opt);
	_create_session($st, $cfg);
}

sub _create_session {
	my ($st, $cfg) = @_;
	my @slots = flatten_tiles($cfg->{root});
	die "pldock: nothing to swallow\n" unless @slots;

	my $X = $st->{X};
	my $root = $st->{root};
	my ($root_w, $root_h) = (800, 600);
	{
		my %g = $X->GetGeometry($root);
		$root_w = $g{width}  if $g{width};
		$root_h = $g{height} if $g{height};
	}

	my @outputs = query_outputs({ w => $root_w, h => $root_h });
	for my $o (@outputs) {
		_v($st, sprintf("xrandr %s %dx%d+%d+%d%s",
			$o->{name}, $o->{w}, $o->{h}, $o->{x}, $o->{y},
			$o->{primary} ? " primary" : ""));
	}
	my $want = $cfg->{screen} || 'primary';
	my $screen = pick_output(\@outputs, $want);
	if (!$screen) {
		my $have = join ", ", map { $_->{name} } @outputs;
		_log('err', "no xrandr output '$want'"
		  . ($have ? " (have: $have)" : ""));
		$screen = pick_output(\@outputs, 'primary') || $outputs[0];
	}
	$screen ||= {
		name => 'default', primary => 1, x => 0, y => 0,
		w => $root_w, h => $root_h,
	};

	my $geo = dock_geometry($cfg, $screen);
	_v($st, sprintf("screen %s %dx%d+%d+%d",
		$screen->{name}, $screen->{w}, $screen->{h},
		$screen->{x}, $screen->{y}));
	_v($st, sprintf("dock %dx%d+%d+%d override=%d",
		$geo->{w}, $geo->{h}, $geo->{x}, $geo->{y},
		$cfg->{override} ? 1 : 0));
	my $win = $X->new_rsrc;
	my %cw = (
		background_pixel => $st->{black},
		border_pixel     => $st->{black},
		bit_gravity      => 'NorthWest',
		event_mask       => $X->pack_event_mask(
			qw(Exposure StructureNotify SubstructureNotify)
		),
	);
	$cw{override_redirect} = 1 if $cfg->{override};

	$X->CreateWindow(
		$win, $root, 'InputOutput', $st->{depth},
		'CopyFromParent',
		$geo->{x}, $geo->{y}, $geo->{w}, $geo->{h}, 0,
		%cw,
	);
	$X->ChangeProperty($win, $st->{WM_NAME},  $st->{STRING}, 8, 'Replace', 'pldock');
	$X->ChangeProperty($win, $st->{WM_CLASS}, $st->{STRING}, 8, 'Replace',
		"pldock\0pldock\0");
	$X->ChangeProperty($win, $st->{WM_PROTO}, $st->{ATOM}, 32, 'Replace',
		pack('L', $st->{WM_DEL}));
	$X->ChangeProperty($win, $st->{NET_TYPE}, $st->{ATOM}, 32, 'Replace',
		pack('L', $st->{NET_DOCK}));
	_apply_strut($X, $win, $st->{NET_STRUT}, $geo->{pos},
		$geo->{x}, $geo->{y}, $geo->{w}, $geo->{h}, $root_w, $root_h);
	$X->MapWindow($win);
	# cwm will otherwise ignore CreateWindow x,y and drop us on the
	# primary. Pin the rectangle to the chosen output.
	$X->ConfigureWindow(
		$win,
		x      => $geo->{x},
		y      => $geo->{y},
		width  => $geo->{w},
		height => $geo->{h},
	);
	$X->GetInputFocus;

	$st->{cfg}         = $cfg;
	$st->{tree}        = $cfg->{root};
	$st->{slots}       = \@slots;
	$st->{dock}        = $win;
	$st->{bar_w}       = $geo->{w};
	$st->{bar_h}       = $geo->{h};
	$st->{pos_x}       = $geo->{x};
	$st->{pos_y}       = $geo->{y};
	$st->{pos}         = $geo->{pos};
	$st->{gap}         = $geo->{gap};
	$st->{height_auto} = $cfg->{height_auto} ? 1 : 0;
	$st->{spawn}       = $cfg->{spawn} ? 1 : 0;
	$st->{want_3d}     = $cfg->{want_3d} ? 1 : 0;
	$st->{override}    = $cfg->{override} ? 1 : 0;
	$st->{screen}      = $screen;
	$st->{root_w}      = $root_w;
	$st->{root_h}      = $root_h;
	$st->{ours}        = { $win => 1 };
	$st->{by_win}      = {};
	$st->{scan_until}  = time() + 30;
	$st->{last_scan}   = 0;

	_relayout($st);
	_start_plugins($st);
	_scan_for_clients($st);
	_spawn_missing($st) if $st->{spawn};
}

sub _plugin_gcs {
	my ($st, $win, $colors, $input) = @_;
	my $X = $st->{X};
	unless ($st->{plugin_font}) {
		my $fid = $X->new_rsrc;
		eval { $X->OpenFont($fid, '6x13') };
		if ($@) {
			eval { $X->OpenFont($fid, 'fixed') };
		}
		$st->{plugin_font} = $@ ? undef : $fid;
	}
	require Pldock::Plugin::Xloadio;
	my @def = Pldock::Plugin::Xloadio::default_colors($input);
	push @def, (0x66CC66, 0xCCCC44, 0xCC6666, 0x66CCCC, 0xCC88CC, 0x888888, 0x4488CC);
	my @cols = @{ $colors || [] };
	my $bgpix = Pldock::Plugin::Xloadio::parse_color($st->{cfg}{plugin_bg});
	$bgpix = $st->{black} unless defined $bgpix;
	my $fgpix = Pldock::Plugin::Xloadio::parse_color($st->{cfg}{plugin_fg});
	$fgpix = $X->white_pixel unless defined $fgpix;
	my %gcopt = (
		foreground => $fgpix,
		background => $bgpix,
		graphics_exposures => 0,
	);
	$gcopt{font} = $st->{plugin_font} if $st->{plugin_font};
	my $fg = $X->new_rsrc;
	$X->CreateGC($fg, $win, %gcopt);
	my $bg = $X->new_rsrc;
	$X->CreateGC($bg, $win, foreground => $bgpix, graphics_exposures => 0);
	my @series;
	for my $i (0 .. 6) {
		my $c = $cols[$i];
		$c = Pldock::Plugin::Xloadio::parse_color($c) if defined $c && $c !~ /^\d+$/;
		$c = $def[$i] unless defined $c;
		my $gc = $X->new_rsrc;
		$X->CreateGC($gc, $win,
			foreground => $c, background => $bgpix,
			graphics_exposures => 0);
		push @series, $gc;
	}
	my $copy = $X->new_rsrc;
	$X->CreateGC($copy, $win, graphics_exposures => 0);
	return {
		fg     => $fg,
		bg     => $bg,
		a      => $series[0],
		b      => $series[1],
		series => \@series,
		bgpix  => $bgpix,
		grid   => _plugin_grid_gc($X, $win, $bgpix),
		copy   => $copy,
	};
}

# Draw into a pixmap then CopyArea to the window so the user never sees
# a cleared frame (erase-then-draw flicker).
sub _plugin_ensure_pix {
	my ($st, $s) = @_;
	my $X = $st->{X};
	my $win = $s->{swallowed} or return;
	my $w = $s->{w} || 1;
	my $h = $s->{h} || 1;
	$w = 1 if $w < 1;
	$h = 1 if $h < 1;
	if ($s->{pix} && ($s->{pix_w} || 0) == $w && ($s->{pix_h} || 0) == $h) {
		return $s->{pix};
	}
	if ($s->{pix}) {
		eval { $X->FreePixmap($s->{pix}) };
		$s->{pix} = undef;
	}
	my $pix = $X->new_rsrc;
	$X->CreatePixmap($pix, $win, $st->{depth}, $w, $h);
	$s->{pix}   = $pix;
	$s->{pix_w} = $w;
	$s->{pix_h} = $h;
	eval {
		$X->ChangeWindowAttributes($win, background_pixmap => $pix);
	};
	return $pix;
}

sub _plugin_paint {
	my ($st, $s) = @_;
	my $X   = $st->{X};
	my $win = $s->{swallowed} or return;
	my $obj = $s->{obj} or return;
	if ($obj->can('is_spinning') && $obj->is_spinning) {
		_plugin_snap_faces($st, $s) unless $s->{faces_ready};
		if (_gl_ready($st)) {
			_plugin_cube($st, $s);
		} else {
			_plugin_barrel($st, $s);
		}
		return;
	}
	my $w   = $s->{w} || 1;
	my $h   = $s->{h} || 1;
	my $pix = _plugin_ensure_pix($st, $s) or return;
	eval { $obj->draw($X, $pix, $s->{gcs}, $w, $h) };
	_plugin_blit($st, $s);
}

sub _plugin_blit {
	my ($st, $s) = @_;
	my $X   = $st->{X};
	my $win = $s->{swallowed} or return;
	my $pix = $s->{pix} or return;
	my $gc  = $s->{gcs}{copy} || $s->{gcs}{fg} or return;
	$X->CopyArea($pix, $win, $gc, 0, 0, $s->{pix_w} || 1, $s->{pix_h} || 1, 0, 0);
}

sub _plugin_face_pix {
	my ($st, $s, $key) = @_;
	my $X = $st->{X};
	my $w = $s->{w} || 1;
	my $h = $s->{h} || 1;
	$s->{face_pix} ||= {};
	$s->{face_wh}  ||= {};
	my $old = $s->{face_pix}{$key};
	if ($old && $s->{face_wh}{$key} && $s->{face_wh}{$key} eq "$w,$h") {
		return $old;
	}
	if ($old) {
		eval { $X->FreePixmap($old) };
	}
	my $pix = $X->new_rsrc;
	$X->CreatePixmap($pix, $s->{swallowed}, $st->{depth}, $w, $h);
	$s->{face_pix}{$key} = $pix;
	$s->{face_wh}{$key}  = "$w,$h";
	return $pix;
}

sub _plugin_snap_faces {
	my ($st, $s) = @_;
	my $obj = $s->{obj} or return;
	return unless $obj->can('face_keys');
	my $X = $st->{X};
	my $w = $s->{w} || 1;
	my $h = $s->{h} || 1;
	my $save = $obj->can('face_state') ? $obj->face_state : undef;
	for my $key ($obj->face_keys) {
		eval { $obj->set_face($key) };
		my $fp = _plugin_face_pix($st, $s, $key);
		eval { $obj->draw($X, $fp, $s->{gcs}, $w, $h) };
		eval {
			my ($depth, $visual, $data) = $X->GetImage(
				$fp, 0, 0, $w, $h, 0xFFFFFFFF, 'ZPixmap'
			);
			if ($data) {
				require Pldock::Plugin::Cube;
				$st->{x_bpp} ||= int(length($data) / ($w * $h)) || 4;
				$s->{face_rgb}{$key} = Pldock::Plugin::Cube::ximage_to_rgb(
					$w, $h, $data, $st->{x_bpp}
				);
			}
		};
	}
	eval { $obj->restore_face($save) } if $save;
	$s->{faces_ready} = 1;
}

sub _gl_ready {
	my ($st) = @_;
	return $st->{gl_ok} if exists $st->{gl_ok};
	$st->{gl_ok} = 0;
	eval { require Pldock::Plugin::Cube };
	if ($@) {
		_v($st, "Cube.pm: $@");
		return 0;
	}
	unless (Pldock::Plugin::Cube::available()) {
		_v($st, "SDL::OpenGL not available");
		return 0;
	}
	if (Pldock::Plugin::Cube::init($st->{X})) {
		$st->{gl_ok} = 1;
		_v($st, "OpenGL cube ready (SDL::OpenGL / cubetest)");
		return 1;
	}
	_v($st, "OpenGL init failed: " . Pldock::Plugin::Cube::last_error());
	if ($st->{want_3d}) {
		_log('err', "--3d OpenGL cube failed ("
		  . (Pldock::Plugin::Cube::last_error() || 'init')
		  . "); using software barrel");
	}
	return 0;
}

sub _plugin_put_rgb {
	my ($st, $s, $rgb, $w, $h) = @_;
	my $X   = $st->{X};
	my $pix = $s->{pix} or return 0;
	my $gc  = $s->{gcs}{copy} || $s->{gcs}{fg} or return 0;
	require Pldock::Plugin::Cube;
	my $bpp = $st->{x_bpp} || 4;
	my $data = ($bpp >= 4)
	  ? Pldock::Plugin::Cube::rgb_to_bgra($rgb, $w, $h)
	  : $rgb;
	eval {
		$X->PutImage(
			$pix, $gc, $st->{depth} || 24,
			$w, $h, 0, 0, 0, 'ZPixmap', $data
		);
	};
	return $@ ? 0 : 1;
}

sub _plugin_cube {
	my ($st, $s) = @_;
	my $obj  = $s->{obj};
	my $spin = $obj->{spin} or return;
	require Pldock::Plugin::Barrel;
	require Pldock::Plugin::Cube;
	my $now = time();
	my $dur = $spin->{dur} || 2;
	my $u   = ($now - ($spin->{t0} || $now)) / $dur;
	if ($u >= 1) {
		eval { $obj->finish_spin };
		$s->{faces_ready} = 0;
		_plugin_paint($st, $s);
		return;
	}
	$u = Pldock::Plugin::Barrel::ease($u);
	my $dir   = $spin->{dir} || 1;
	my $angle = 90 * $dir * $u;
	my $w     = $s->{w} || 1;
	my $h     = $s->{h} || 1;
	my @keys  = @{ $spin->{keys} || [] };
	my $n     = @keys || 1;
	my $from  = $spin->{from} || 0;
	my @rgb;
	for my $k (0 .. 5) {
		my $ki;
		if ($k == 0) {
			$ki = $from % $n;
		} elsif ($k == 1) {
			$ki = ($from + 1) % $n;
		} elsif ($k == 2) {
			$ki = ($from + 2) % $n;
		} elsif ($k == 3) {
			$ki = ($from - 1) % $n;
		}
		if (defined $ki) {
			$rgb[$k] = $s->{face_rgb}{ $keys[$ki] };
		}
	}
	Pldock::Plugin::Cube::upload_faces($w, $h, @rgb);
	my $frame = Pldock::Plugin::Cube::render_rgb($angle, $w, $h);
	unless ($frame && length($frame) >= $w * $h * 3) {
		_plugin_barrel($st, $s);
		return;
	}
	_plugin_ensure_pix($st, $s);
	unless (_plugin_put_rgb($st, $s, $frame, $w, $h)) {
		_plugin_barrel($st, $s);
		return;
	}
	_plugin_blit($st, $s);
}

sub _plugin_barrel {
	my ($st, $s) = @_;
	my $obj = $s->{obj};
	require Pldock::Plugin::Barrel;
	my $spin = $obj->{spin} or return;
	my $now  = time();
	my $dur  = $spin->{dur} || 2;
	my $u    = ($now - ($spin->{t0} || $now)) / $dur;
	if ($u >= 1) {
		eval { $obj->finish_spin };
		$s->{faces_ready} = 0;
		_plugin_paint($st, $s);
		return;
	}
	my $n    = $spin->{n} || 2;
	my $from = $spin->{from} || 0;
	my $dir  = $spin->{dir} || 1;
	my $w    = $s->{w} || 1;
	my $h    = $s->{h} || 1;
	my $pix  = _plugin_ensure_pix($st, $s) or return;
	my $X    = $st->{X};
	my $bg   = $s->{gcs}{bg};
	my $copy = $s->{gcs}{copy} || $s->{gcs}{fg};
	$X->PolyFillRectangle($pix, $bg, [ 0, 0, $w, $h ]) if $bg;
	my @faces = Pldock::Plugin::Barrel::visible_faces($from, $n, $dir, $u);
	for my $f (@faces) {
		my $key = $spin->{keys}[ $f->{i} ];
		my $src = $s->{face_pix}{$key} or next;
		my ($x0, $dw) = Pldock::Plugin::Barrel::strip($f, $w);
		next if $dw < 1;
		for my $dx (0 .. $dw - 1) {
			my $sx = Pldock::Plugin::Barrel::src_col($dx, $dw, $w);
			my $dxs = $x0 + $dx;
			next if $dxs < 0 || $dxs >= $w;
			$X->CopyArea($src, $pix, $copy, $sx, 0, 1, $h, $dxs, 0);
		}
	}
	_plugin_blit($st, $s);
}

sub _plugin_grid_gc {
	my ($X, $win, $bgpix) = @_;
	my $gc = $X->new_rsrc;
	$X->CreateGC($gc, $win,
		foreground => 0x444444, background => $bgpix,
		graphics_exposures => 0);
	return $gc;
}

sub _slot_colors {
	my ($s) = @_;
	my @cols;
	for my $i (0 .. 7) {
		push @cols, $s->{"color$i"} if defined $s->{"color$i"};
	}
	if (!@cols && defined $s->{colors}) {
		@cols = grep { length } split /,/, $s->{colors};
	}
	return @cols;
}

sub _start_plugins {
	my ($st) = @_;
	my $X = $st->{X};
	require Pldock::Plugin;
	for my $s (@{ $st->{slots} }) {
		next unless ($s->{type} || '') eq 'plugin'
		         || ($s->{type} || '') eq 'script';
		my $obj;
		eval {
			$obj = Pldock::Plugin::load(
				$s->{plugin} || 'script',
				input   => $s->{input} || 'disk',
				style   => $s->{style},
				cmd     => $s->{cmd},
				freq    => $s->{freq},
				colors  => [ _slot_colors($s) ],
				want_3d => $st->{want_3d} ? 1 : 0,
			);
		};
		if ($@ || !$obj) {
			_log('err', "plugin $s->{plugin}: $@");
			next;
		}
		my $win = $X->new_rsrc;
		my $pw = $s->{w} || $s->{slot_w} || 120;
		my $ph = $s->{h} || $s->{slot_h} || 57;
		my $px = $s->{x} || 0;
		my $py = $s->{y} || 0;
		$X->CreateWindow(
			$win, $st->{dock}, 'InputOutput', $st->{depth},
			'CopyFromParent',
			$px, $py, ($pw > 0 ? $pw : 1), ($ph > 0 ? $ph : 1), 0,
			background_pixel => $st->{black},
			border_pixel     => $st->{black},
			event_mask       => $X->pack_event_mask(
				qw(Exposure ButtonPress ButtonRelease StructureNotify)
			),
		);
		$X->MapWindow($win);
		$s->{obj}        = $obj;
		$s->{swallowed}  = $win;
		$s->{is_plugin}  = 1;
		$s->{gcs}        = _plugin_gcs($st, $win, [ _slot_colors($s) ], $s->{input});
		$st->{ours}{$win} = 1;
		$st->{by_win}{$win} = $s;
		$st->{plugin_win}{$win} = $s;
		_v($st, "plugin $s->{id} window 0x" . sprintf('%x', $win));
		eval { $obj->sample };
		_plugin_paint($st, $s);
	}
}

sub _plugin_tick {
	my ($st) = @_;
	my $X = $st->{X};
	for my $s (@{ $st->{slots} || [] }) {
		next unless $s->{is_plugin} && $s->{obj} && $s->{swallowed};
		if ($s->{obj}->can('is_spinning') && $s->{obj}->is_spinning) {
			_plugin_paint($st, $s);
		} elsif (!$s->{obj}->can('due') || $s->{obj}->due) {
			eval { $s->{obj}->sample };
			_plugin_paint($st, $s);
		}
	}
}

sub _plugin_event {
	my ($st, $ev) = @_;
	# ButtonPress names the window `event`, not `window`.
	my $w = $ev->{window} // $ev->{event} // 0;
	my $s = $st->{plugin_win}{$w} or return 0;
	my $name = $ev->{name} // '';
	if ($name eq 'Expose') {
		return 1 if ($ev->{count} // 0) != 0;
		if ($s->{pix}) {
			_plugin_blit($st, $s);
		} else {
			_plugin_paint($st, $s);
		}
		return 1;
	}
	if ($name eq 'ButtonPress' || $name eq 'ButtonRelease') {
		return 1 if $name eq 'ButtonRelease' && $s->{click_armed};
		my $x = $ev->{event_x} // 0;
		my $y = $ev->{event_y} // 0;
		my $btn = $ev->{detail} || 1;
		if ($s->{obj} && $s->{obj}->click($x, $y, $s->{w} || 1, $s->{h} || 1, $btn)) {
			$s->{click_armed} = 1 if $name eq 'ButtonPress';
			eval { $s->{obj}->sample };
			_plugin_paint($st, $s);
			$st->{X}->GetInputFocus;
		}
		$s->{click_armed} = 0 if $name eq 'ButtonRelease';
		return 1;
	}
	return 1;
}

sub _disarm {
	my ($st) = @_;
	_destroy_plugins($st);
	_spit_all($st);
	my $X = $st->{X} or return;
	if ($st->{dock}) {
		eval { $X->DestroyWindow($st->{dock}) };
		eval { $X->GetInputFocus };
	}
	$st->{dock}       = undef;
	$st->{ours}       = {};
	$st->{by_win}     = {};
	$st->{plugin_win} = {};
}

sub _destroy_plugins {
	my ($st) = @_;
	my $X = $st->{X} or return;
	for my $s (@{ $st->{slots} || [] }) {
		next unless $s->{is_plugin};
		my $w = $s->{swallowed} or next;
		if ($s->{pix}) {
			eval { $X->FreePixmap($s->{pix}) };
			$s->{pix} = undef;
		}
		if ($s->{face_pix}) {
			for my $fp (values %{ $s->{face_pix} }) {
				eval { $X->FreePixmap($fp) };
			}
			$s->{face_pix} = {};
			$s->{faces_ready} = 0;
		}
		eval { $X->DestroyWindow($w) };
		delete $st->{ours}{$w};
		delete $st->{by_win}{$w};
		delete $st->{plugin_win}{$w};
		$s->{swallowed} = undef;
		$s->{obj}       = undef;
		$s->{gcs}       = undef;
	}
}

sub _handle_event {
	my ($st, $ev) = @_;
	my $name = $ev->{name} // "";
	my $X = $st->{X};
	my $dock = $st->{dock};

	return if _plugin_event($st, $ev);

	if ($name eq 'Expose') {
		return unless $dock && ($ev->{window} // 0) == $dock;
		return if ($ev->{count} // 0) != 0;
		$X->ClearArea($dock, 0, 0, 0, 0, 0);
	} elsif ($name eq 'ConfigureNotify') {
		if ($dock && ($ev->{window} // 0) == $dock && ($ev->{event} // 0) == $dock) {
			my $ex = $ev->{x};
			my $ey = $ev->{y};
			my $ew = $ev->{width};
			my $eh = $ev->{height};
			if ($st->{override}
			    && defined $ex && defined $ey
			    && ($ex != $st->{pos_x} || $ey != $st->{pos_y}
			        || (defined $ew && $ew != $st->{bar_w})
			        || (defined $eh && $eh != $st->{bar_h}))) {
				_v($st, sprintf(
					"wm moved dock to %dx%d+%d+%d; putting back +%d+%d",
					$ew // $st->{bar_w}, $eh // $st->{bar_h},
					$ex, $ey, $st->{pos_x}, $st->{pos_y}));
				$X->ConfigureWindow(
					$dock,
					x      => $st->{pos_x},
					y      => $st->{pos_y},
					width  => $st->{bar_w},
					height => $st->{bar_h},
				);
				return;
			}
			_relayout($st);
		}
	} elsif ($name eq 'ClientMessage') {
		if (($ev->{window} // 0) == $dock) {
			$st->{quit} = 1;
		}
	} elsif ($name eq 'MapNotify' || $name eq 'CreateNotify') {
		my $w = $ev->{window} // 0;
		_consider_window($st, $w) if $w;
	} elsif ($name eq 'DestroyNotify') {
		my $w = $ev->{window} // 0;
		_unswallow($st, $w) if $w;
	} elsif ($name eq 'ReparentNotify') {
		my $w = $ev->{window} // 0;
		return unless $w;
		return if $st->{by_win}{$w};
		_consider_window($st, $w);
	}
}

sub _unswallow {
	my ($st, $w) = @_;
	my $slot = $st->{by_win}{$w} or return;
	delete $st->{by_win}{$w};
	delete $st->{ours}{$w};
	$slot->{swallowed} = undef;
	$slot->{dummy} = undef if ($slot->{dummy} // 0) == $w;
}

sub _apply_strut {
	my ($X, $win, $net_strut, $pos, $x, $y, $w, $h, $root_w, $root_h) = @_;
	my @strut = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
	if (($pos || '') =~ /top/) {
		$strut[2] = $h;
		$strut[8] = $x;
		$strut[9] = $x + $w;
	} else {
		$strut[3] = $h;
		$strut[10] = $x;
		$strut[11] = $x + $w;
	}
	$X->ChangeProperty($win, $net_strut, $X->atom('CARDINAL'), 32, 'Replace',
		pack('L*', @strut));
}

sub _relayout {
	my ($st) = @_;
	my $X = $st->{X};
	if ($st->{height_auto} && $st->{tree} && $st->{cfg} && $st->{screen}) {
		my $geo = dock_geometry($st->{cfg}, $st->{screen});
		if ($geo->{h} != $st->{bar_h}
		    || $geo->{w} != $st->{bar_w}
		    || $geo->{x} != $st->{pos_x}
		    || $geo->{y} != $st->{pos_y}) {
			$st->{bar_w} = $geo->{w};
			$st->{bar_h} = $geo->{h};
			$st->{pos_x} = $geo->{x};
			$st->{pos_y} = $geo->{y};
			$st->{pos}   = $geo->{pos};
			$X->ConfigureWindow(
				$st->{dock},
				x      => $st->{pos_x},
				y      => $st->{pos_y},
				width  => $st->{bar_w},
				height => $st->{bar_h},
			);
			_apply_strut(
				$X, $st->{dock}, $st->{NET_STRUT}, $st->{pos},
				$st->{pos_x}, $st->{pos_y}, $st->{bar_w}, $st->{bar_h},
				$st->{root_w}, $st->{root_h},
			) if $st->{NET_STRUT};
		}
	}
	layout_tree($st->{tree}, $st->{bar_w}, $st->{bar_h}, $st->{gap});
	for my $s (@{ $st->{slots} }) {
		next unless $s->{swallowed};
		my $x = $s->{x} // 0;
		my $y = $s->{y} // 0;
		if ($s->{stretch}) {
			$X->ConfigureWindow(
				$s->{swallowed},
				x            => $x,
				y            => $y,
				width        => ($s->{w} > 0 ? $s->{w} : 1),
				height       => ($s->{h} > 0 ? $s->{h} : 1),
				border_width => 0,
			);
		} else {
			$X->ConfigureWindow(
				$s->{swallowed},
				x            => $x,
				y            => $y,
				border_width => 0,
			);
		}
		if ($s->{is_plugin} && $s->{obj}) {
			_plugin_paint($st, $s);
		}
	}
	$X->GetInputFocus;
}

sub _spawn_missing {
	my ($st) = @_;
	return unless $st->{spawn};
	my $now = time();
	for my $s (@{ $st->{slots} }) {
		next if ($s->{type} || '') eq 'plugin'
		     || ($s->{type} || '') eq 'script';
		next if $s->{swallowed};
		next if $s->{pid} && kill(0, $s->{pid});
		if ($s->{fails} && $s->{fails} >= RESPAWN_MAX) {
			next;
		}
		if ($s->{next_spawn} && $now < $s->{next_spawn}) {
			next;
		}
		_spawn_slot($st, $s);
	}
}

sub _spawn_slot {
	my ($st, $s) = @_;
	my $X = $st->{X};
	my $xfd = $st->{xfd};
	my @argv = @{ $s->{argv} };
	my $pid = fork;
	if (!defined $pid) {
		warn "pldock: fork: $!\n";
		return;
	}
	if ($pid == 0) {
		eval { POSIX::close($xfd) };
		setpgrp(0, 0);
		open STDIN,  '<', '/dev/null';
		open STDOUT, '>', '/dev/null';
		open STDERR, '>', '/dev/null';
		exec { $argv[0] } @argv or _exit(127);
	}
	$s->{pid} = $pid;
	$s->{spawned_at} = time();
	$s->{next_spawn} = 0;
	$st->{scan_until} = time() + 30;
}

sub _reap {
	my ($st) = @_;
	while (1) {
		my $pid = waitpid(-1, WNOHANG);
		last if !defined $pid || $pid <= 0;
		for my $s (@{ $st->{slots} }) {
			next unless ($s->{pid} // 0) == $pid;
			$s->{pid} = undef;
			$s->{fails} = ($s->{fails} || 0) + 1;
			my $n = $s->{fails};
			$s->{next_spawn} = time() + ($n < 4 ? (1 << ($n - 1)) * 0.5 : 4);
			if ($n >= RESPAWN_MAX) {
				warn "pldock: $s->{id} exited $n times; giving up\n";
			}
		}
	}
}

sub _ok_reply {
	my @r = @_;
	return unless @r && ref $r[0] eq 'ARRAY';
	return @{ $r[0] };
}

sub _v {
	my ($st, $msg) = @_;
	return unless $st && $st->{verbose};
	_log('info', $msg);
}

sub _candidate_windows {
	my ($st) = @_;
	my $X = $st->{X};
	my @ids;
	my (undef, undef, @top) = _ok_reply($X->robust_req('QueryTree', $st->{root}));
	for my $w (@top) {
		next if $st->{ours}{$w};
		push @ids, $w;
		my (undef, undef, @kids) = _ok_reply($X->robust_req('QueryTree', $w));
		for my $c (@kids) {
			next if $st->{ours}{$c};
			push @ids, $c;
		}
	}
	my @cands;
	for my $w (@ids) {
		my ($inst, $class) = _get_class($st, $w);
		my $name = _get_name($st, $w);
		push @cands, {
			w     => $w,
			inst  => $inst,
			class => $class,
			name  => $name,
		};
	}
	return @cands;
}

sub _scan_for_clients {
	my ($st) = @_;
	return unless any_unfilled($st->{slots});
	my @cands = _candidate_windows($st);
	for my $s (@{ $st->{slots} }) {
		next if $s->{swallowed};
		next if ($s->{type} || '') eq 'plugin'
		     || ($s->{type} || '') eq 'script';
		my $want = join ",", @{ $s->{match} || [] };
		_v($st, "looking for $s->{id} name=$want");
		my $hit;
		for my $c (@cands) {
			if (class_matches_slot($c->{inst}, $c->{class}, $c->{name}, $s)) {
				$hit = $c;
				last;
			}
		}
		if (!$hit) {
			_v($st, "$s->{id}: not found");
			next;
		}
		_v($st, sprintf(
			"%s: found 0x%x name=\"%s\" class=\"%s\"/\"%s\"",
			$s->{id}, $hit->{w}, $hit->{name} // "",
			$hit->{inst} // "", $hit->{class} // ""));
		_consider_window($st, $hit->{w});
		if ($s->{swallowed}) {
			_v($st, sprintf("%s: ingested 0x%x", $s->{id}, $s->{swallowed}));
		} else {
			_v($st, "$s->{id}: found but not ingested");
		}
	}
}

sub _get_class {
	my ($st, $w) = @_;
	my ($val) = _ok_reply($st->{X}->robust_req(
		'GetProperty', $w, $st->{WM_CLASS}, 'AnyPropertyType', 0, 256, 0
	));
	return parse_wm_class($val);
}

sub _get_name {
	my ($st, $w) = @_;
	my ($val) = _ok_reply($st->{X}->robust_req(
		'GetProperty', $w, $st->{WM_NAME}, 'AnyPropertyType', 0, 256, 0
	));
	return '' unless defined $val;
	$val =~ s/\0.*//s;
	return $val;
}

sub _get_hints {
	my ($st, $w) = @_;
	my ($val) = _ok_reply($st->{X}->robust_req(
		'GetProperty', $w, $st->{WM_HINTS}, $st->{WM_HINTS}, 0, 9, 0
	));
	return unpack_wm_hints($val);
}

sub _consider_window {
	my ($st, $w) = @_;
	return unless $w;
	return if $st->{ours}{$w};
	return if $st->{by_win}{$w};
	my $X = $st->{X};
	my ($inst, $class) = _get_class($st, $w);
	my $name = _get_name($st, $w);
	my $slot;
	for my $s (@{ $st->{slots} }) {
		next if $s->{swallowed};
		if (class_matches_slot($inst, $class, $name, $s)) {
			$slot = $s;
			last;
		}
	}
	return unless $slot;

	my $target = $w;
	my $hints = _get_hints($st, $w);
	my $icon = hints_icon_window($hints);
	if ($icon && $icon != $w) {
		$target = $icon;
		$slot->{dummy} = $w;
	}
	return if $st->{ours}{$target};
	_swallow($st, $slot, $target, $w);
}

sub _swallow {
	my ($st, $slot, $target, $matched) = @_;
	my $X = $st->{X};
	my $dock = $st->{dock};
	return if $slot->{swallowed};

	my %geo = _ok_reply($X->robust_req('GetGeometry', $target));
	my @tr = _ok_reply($X->robust_req(
		'TranslateCoordinates', $target, $st->{root}, 0, 0
	));
	$slot->{restore_x} = $tr[2] if @tr >= 4;
	$slot->{restore_y} = $tr[3] if @tr >= 4;
	$slot->{restore_w} = $geo{width}  if $geo{width};
	$slot->{restore_h} = $geo{height} if $geo{height};
	if (%geo && !$slot->{stretch} && !$slot->{size_locked}) {
		# Dockapps often have a large X window with SHAPE punching a
		# 54x57 hole. Using GetGeometry as the slot width leaves a
		# black gap and squeezes stretch plugins. Honor the hint
		# unless the real size is only a little bigger (e.g. 64x64).
		my $gw = $geo{width}  || 0;
		my $gh = $geo{height} || 0;
		my $cap_w = ($slot->{content_w} || 64) + 16;
		my $cap_h = ($slot->{content_h} || 64) + 16;
		$slot->{w} = $gw if $gw && $gw <= $cap_w;
		$slot->{h} = $gh if $gh && $gh <= $cap_h;
		$slot->{content_w} = $slot->{w} if $slot->{w};
		$slot->{content_h} = $slot->{h} if $slot->{h};
	}

	_relayout($st);

	my $x = $slot->{x} // 0;
	my $y = $slot->{y} // 0;

	$X->UnmapWindow($target);
	$X->ChangeSaveSet('Insert', $target);
	$X->ReparentWindow($target, $dock, $x, $y);
	if ($slot->{stretch}) {
		my $w = $slot->{slot_w} || 1;
		my $h = $slot->{slot_h} || $st->{bar_h} || 1;
		$X->ConfigureWindow(
			$target,
			x            => $x,
			y            => $y,
			width        => $w,
			height       => $h,
			border_width => 0,
		);
	} else {
		$X->ConfigureWindow($target, x => $x, y => $y, border_width => 0);
	}
	$X->MapWindow($target);

	if ($matched && $matched != $target) {
		eval { $X->UnmapWindow($matched) };
		$st->{ours}{$matched} = 1;
	}

	$slot->{swallowed} = $target;
	$st->{by_win}{$target} = $slot;
	$st->{ours}{$target} = 1;
	$st->{ours}{$dock} = 1;
	$X->GetInputFocus;
}

sub _spit_all {
	my ($st) = @_;
	return unless $st->{slots};
	for my $s (@{ $st->{slots} }) {
		_spit_slot($st, $s);
	}
}

sub _spit_slot {
	my ($st, $s) = @_;
	return if $s->{is_plugin};
	my $win = $s->{swallowed} or return;
	my $X = $st->{X};
	my $root = $st->{root};
	my $x = $s->{restore_x} // 0;
	my $y = $s->{restore_y} // 0;
	eval {
		$X->UnmapWindow($win);
		$X->ReparentWindow($win, $root, $x, $y);
		$X->ChangeSaveSet('Delete', $win);
		if ($s->{restore_w} && $s->{restore_h}) {
			$X->ConfigureWindow(
				$win,
				x            => $x,
				y            => $y,
				width        => $s->{restore_w},
				height       => $s->{restore_h},
				border_width => 0,
			);
		}
		$X->MapWindow($win);
	};
	if (my $dummy = $s->{dummy}) {
		eval { $X->MapWindow($dummy) };
		delete $st->{ours}{$dummy};
	}
	delete $st->{by_win}{$win};
	delete $st->{ours}{$win};
	$s->{swallowed} = undef;
	$s->{dummy}     = undef;
	$s->{pid}       = undef;
}

1;

__END__

=head1 NAME

Pldock - swallow wmclock/wmapm/xload/xconsole into an X11 rectangle

=head1 SYNOPSIS

  perl -Ilib ./pldock
  perl -Ilib ./pldock -override -screen HDMI-1
  perl -Ilib ./pldock -c ./pldock.conf
  kill -HUP <pid>     # spit, reload conf, ingest again
