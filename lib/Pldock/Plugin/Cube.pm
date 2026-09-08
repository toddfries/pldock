package Pldock::Plugin::Cube;

# OpenGL textured cube, borrowed from ./cubetest (SDL::OpenGL).
# Copyright (c) 2026 Todd T. Fries <todd@fries.net>

use strict;
use warnings;

# Front (+Z) is the current xloadio face at angle 0 — same as cubetest.
my @FACES = (
	[ [ -1, -1,  1 ], [  1, -1,  1 ], [  1,  1,  1 ], [ -1,  1,  1 ] ],
	[ [  1, -1,  1 ], [  1, -1, -1 ], [  1,  1, -1 ], [  1,  1,  1 ] ],
	[ [  1, -1, -1 ], [ -1, -1, -1 ], [ -1,  1, -1 ], [  1,  1, -1 ] ],
	[ [ -1, -1, -1 ], [ -1, -1,  1 ], [ -1,  1,  1 ], [ -1,  1, -1 ] ],
	[ [ -1,  1,  1 ], [  1,  1,  1 ], [  1,  1, -1 ], [ -1,  1, -1 ] ],
	[ [ -1, -1, -1 ], [  1, -1, -1 ], [  1, -1,  1 ], [ -1, -1,  1 ] ],
);
my @UV = ( [ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 0, 1 ] );

my $READY;
my $APP;
my @TEX;
my $GL_W = 256;
my $GL_H = 256;
my $LAST_ERR = '';

sub last_error { $LAST_ERR }

sub available {
	return 1 if $READY;
	return 0 if $LAST_ERR eq 'no';
	eval { require SDL::App; require SDL::OpenGL; 1 };
	return $@ ? 0 : 1;
}

sub pot {
	my ($n) = @_;
	$n = 1 if !$n || $n < 1;
	my $p = 1;
	$p <<= 1 while $p < $n;
	return $p;
}

sub yflip_rgb {
	my ($rgb, $w, $h) = @_;
	return $rgb unless $rgb && $w && $h;
	my $row = $w * 3;
	return $rgb unless $row * $h == length($rgb);
	my $out = '';
	for (my $y = $h - 1; $y >= 0; $y--) {
		$out .= substr($rgb, $y * $row, $row);
	}
	return $out;
}

# X ZPixmap → packed RGB. 24/32-bit little-endian TrueColor is usually BGRA.
sub ximage_to_rgb {
	my ($w, $h, $data, $bpp) = @_;
	return '' unless $data && $w && $h;
	$bpp ||= int(length($data) / ($w * $h));
	$bpp = 4 if $bpp < 3;
	my $out = '';
	if ($bpp == 3) {
		return $data if length($data) >= $w * $h * 3;
	}
	my $src = 0;
	my $need = $w * $h;
	for (my $i = 0; $i < $need; $i++) {
		last if $src + 3 > length($data);
		my ($b, $g, $r) = unpack('C3', substr($data, $src, 3));
		$out .= pack('C3', $r, $g, $b);
		$src += $bpp;
	}
	return $out;
}

sub rgb_to_bgra {
	my ($rgb, $w, $h) = @_;
	my $out = '';
	my $n = $w * $h;
	my $i = 0;
	for (my $p = 0; $p < $n; $p++) {
		my ($r, $g, $b) = unpack('C3', substr($rgb, $i, 3));
		$out .= pack('C4', $b, $g, $r, 0);
		$i += 3;
	}
	return $out;
}

sub pad_rgb {
	my ($rgb, $w, $h, $tw, $th) = @_;
	$tw ||= $w;
	$th ||= $h;
	return ($rgb, $w, $h) if $tw == $w && $th == $h;
	my $out = "\0" x ($tw * $th * 3);
	my $src_row = $w * 3;
	my $dst_row = $tw * 3;
	for my $y (0 .. $h - 1) {
		substr($out, $y * $dst_row, $src_row) = substr($rgb, $y * $src_row, $src_row);
	}
	return ($out, $tw, $th);
}

sub init {
	my ($X) = @_;
	return 1 if $READY;
	eval {
		require SDL::App;
		require SDL::OpenGL;
		SDL::OpenGL->import();
		1;
	};
	if ($@) {
		$LAST_ERR = $@;
		return 0;
	}
	eval { _init_sdl_gl($X) };
	if ($@) {
		$LAST_ERR = $@;
		return 0;
	}
	$READY = 1;
	return 1;
}

sub _init_sdl_gl {
	my ($X) = @_;
	if ($X) {
		my $win = $X->new_rsrc;
		$X->CreateWindow(
			$win, $X->root, 'InputOutput', $X->root_depth,
			'CopyFromParent',
			-400, -400, $GL_W, $GL_H, 0,
			override_redirect => 1,
			background_pixel  => $X->black_pixel,
		);
		$X->MapWindow($win);
		$X->GetInputFocus;
		$ENV{SDL_VIDEODRIVER} ||= 'x11';
		$ENV{SDL_WINDOWID} = $win + 0;
	}
	$APP = SDL::App->new(
		-title         => 'pldock-gl',
		-width         => $GL_W,
		-height        => $GL_H,
		-depth         => 16,
		-gl            => 1,
		-double_buffer => 1,
	);
	glClearColor(0.05, 0.05, 0.07, 1);
	glEnable(GL_DEPTH_TEST());
	glEnable(GL_TEXTURE_2D());
	eval { glPixelStore(GL_UNPACK_ALIGNMENT(), 1) };
	eval { glPixelStore(GL_PACK_ALIGNMENT(), 1) };
	@TEX = eval { glGenTextures(6) };
	@TEX = ( 1, 2, 3, 4, 5, 6 ) unless @TEX == 6;
	for my $i (0 .. 5) {
		_upload_tex($i, _dark_rgb(8, 8), 8, 8);
	}
}

sub _dark_rgb {
	my ($w, $h) = @_;
	return pack('C3', 20, 20, 30) x ($w * $h);
}

sub _upload_tex {
	my ($i, $rgb, $w, $h) = @_;
	my $tw = pot($w);
	my $th = pot($h);
	($rgb, $tw, $th) = pad_rgb($rgb, $w, $h, $tw, $th);
	glBindTexture(GL_TEXTURE_2D(), $TEX[$i]);
	glTexParameter(GL_TEXTURE_2D(), GL_TEXTURE_MIN_FILTER(), GL_LINEAR());
	glTexParameter(GL_TEXTURE_2D(), GL_TEXTURE_MAG_FILTER(), GL_LINEAR());
	eval { glTexParameter(GL_TEXTURE_2D(), GL_TEXTURE_WRAP_S(), GL_CLAMP()) };
	eval { glTexParameter(GL_TEXTURE_2D(), GL_TEXTURE_WRAP_T(), GL_CLAMP()) };
	glTexImage2D(
		GL_TEXTURE_2D(), 0, 3, $tw, $th, 0,
		GL_RGB(), GL_UNSIGNED_BYTE(), $rgb
	);
}

# @rgb_faces : up to 6 packed RGB strings (same w x h)
sub upload_faces {
	my ($w, $h, @rgb) = @_;
	return unless $READY;
	for my $i (0 .. 5) {
		my $pix = $rgb[$i] || _dark_rgb($w, $h);
		_upload_tex($i, $pix, $w, $h);
	}
}

sub _draw_cube {
	for my $f (0 .. 5) {
		glBindTexture(GL_TEXTURE_2D(), $TEX[$f]);
		glBegin(GL_QUADS());
		for my $v (0 .. 3) {
			glTexCoord(@{ $UV[$v] });
			glVertex(@{ $FACES[$f][$v] });
		}
		glEnd();
	}
}

# Returns bottom-up RGB from the GL back buffer, then y-flipped to X order.
sub render_rgb {
	my ($angle, $dw, $dh) = @_;
	return unless $READY;
	$dw ||= 64;
	$dh ||= 64;
	$dw = $GL_W if $dw > $GL_W;
	$dh = $GL_H if $dh > $GL_H;
	$dw = 2 if $dw < 2;
	$dh = 2 if $dh < 2;
	glViewport(0, 0, $dw, $dh);
	glMatrixMode(GL_PROJECTION());
	glLoadIdentity();
	gluPerspective(35, $dw / $dh, 0.5, 20);
	glMatrixMode(GL_MODELVIEW());
	glClear(GL_COLOR_BUFFER_BIT() | GL_DEPTH_BUFFER_BIT());
	glLoadIdentity();
	glTranslate(0, 0, -5.5);
	glRotate($angle, 0, 1, 0);
	_draw_cube();
	glFlush();
	my $buf = eval {
		glReadPixels(0, 0, $dw, $dh, GL_RGB(), GL_UNSIGNED_BYTE());
	};
	if (!$buf || length($buf) < $dw * $dh * 3) {
		$buf = "\0" x ($dw * $dh * 3);
		eval {
			glReadPixels(0, 0, $dw, $dh, GL_RGB(), GL_UNSIGNED_BYTE(), $buf);
		};
	}
	eval { $APP->sync if $APP };
	return yflip_rgb($buf, $dw, $dh);
}

1;
