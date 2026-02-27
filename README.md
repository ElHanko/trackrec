# trackrec

Application-specific track recording via **PipeWire** and **MPRIS**.

`trackrec` records audio that is already being played locally, routes it through a dedicated PipeWire sink, and splits recordings cleanly per track using MPRIS playback events. It is a **CLI-first**, transparent toolchain with no background services and no platform-specific APIs.

---

## Features

* Dedicated recording sink (`rec`) – no desktop/system sounds in captures
* Optional loopback for monitoring (listen on/off)
* Track-accurate start/stop via MPRIS (`PlaybackStatus` + `Metadata`)
* Lossless FLAC output with tags (artist, title, album, track/disc numbers, source URL if available)
* Minimum-duration filter to drop junk clips
* Duplicate protection based on track URL
* Clean setup and teardown (no leftovers)
* Status inspection via CLI (also works over SSH)

---

## Requirements

* Linux with **PipeWire** (and `pipewire-pulse`)
* `ffmpeg` (with FLAC support)
* Python ≥ 3.10
* Python packages: `python3-dbus`, `python3-gi`

```bash
sudo apt install ffmpeg python3-dbus python3-gi
```

---

## Installation

Clone the repository and install user-local symlinks:

```bash
cd $HOME/trackrec
./install.sh
source ~/.profile
```

All commands are installed to `~/.local/bin`.

---

## Usage

Start playback in any MPRIS-capable player (e.g. a desktop media player), then:

```bash
trackrec-run <pattern>
```

* `<pattern>` matches the application stream name (case-insensitive)

Optional monitoring:

```bash
trackrec-run <pattern> --listen
```

Stop with `Ctrl+C` – routing and loopbacks are reverted automatically.

---

## Status & Monitoring

```bash
trackrec-status
```

Live view:

```bash
trackrec-status --watch
```

Machine-readable output:

```bash
trackrec-status --json
```

---

## Audio Notes

* Recording is taken from the local PipeWire graph
* Typical live setups run at 48 kHz; this is fine for DJ use
* FLAC preserves the captured signal without inventing quality

---

## Responsibility

This tool records **local audio output**. Users are responsible for complying with the terms of service and applicable laws for any application they use it with.

---

## License

MIT
