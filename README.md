# pldock

A small Perl X11 dock: one dark rectangle that **swallows** `wmclock`,
`wmapm`, `xload`, and `xconsole`.

The X bits follow xtomato `plxmessage` / `Xtomato::Plxmessage`:
`X11::Protocol`, `CreateWindow`, ICCCM properties, and a `select()` event
loop. There is no toolkit and no XCB twin.

## Run

`$DISPLAY` must already be set (this program will not default it).

```
perl -Ilib -c pldock
./pldock
./pldock -override
./pldock -c ./pldock.conf
```

Needs `p5-X11-Protocol`. Clients are looked up on `$PATH`.

## Layout config

Default: **lower right of the xrandr primary output**, xconsole along the
bottom, the other three tiled in a row above it. Existing mapped clients
are ingested; pldock does not fork them unless you set `spawn` or pass
`-spawn`. Ctrl-C / SIGTERM reparents those windows back to the root.
SIGHUP spits them out, re-reads the config, and swallows them again.

```
# pldock.conf
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
```

`hbox` is a row, `vbox` a column. `stretch` takes leftover space on that
box’s main axis. `width` / `height` are relative to the chosen **xrandr
output** (`screen primary`, `HDMI-1`, `right`, …). Nested boxes can go as
deep as you want.

```
perl -Ilib -e 'print "$_->{name} $_->{w}x$_->{h}+$_->{x}+$_->{y}\n"
  for Pldock::parse_xrandr(Pldock::read_xrandr_text())'
```

Search path: `-c FILE`, `$PLDOCK_CONF`, `~/.config/pldock/pldock.conf`,
`~/.pldock.conf`, `pldock.conf` beside the script, then the built-in
default.

## cwm

`~/.cwmrc` already ignores `xload` / `xconsole`. Add:

```
ignore pldock
```

The dock is **override-redirect** by default so `-screen HDMI-1` is not
stolen by cwm. Pass `-managed` if you want the WM to place it.

```
./pldock -v -screen HDMI-1
```

logs each xrandr output, the dock rectangle, and every ingest attempt
(`looking for wmapm` / `found` / `ingested` / `not found`).

`xconsole` may exit if it cannot read `/dev/console`; pldock gives up after
a few respawns.

## Files

| Path | Role |
|------|------|
| `pldock` | CLI stub |
| `pldock.1` | mandoc for the command |
| `pldock.conf` | default layout |
| `pldock.conf.1` | mandoc for the layout language |
| `lib/Pldock.pm` | dock + swallow + conf |
| `t/` | layout / conf / WM_CLASS (no live X) |
