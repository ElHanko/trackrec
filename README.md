# trackrec

Track-aware audio recorder for Linux using **PipeWire** and **MPRIS**.

`trackrec` records audio already being played locally, routes it through a dedicated PipeWire sink, and splits recordings per track using MPRIS playback events.

It provides a **single CLI entrypoint** (`trackrec`) with subcommands, while keeping the internal tools modular.

PipeWire • MPRIS • CLI-first • FLAC/MP3

---

# Features

- Dedicated recording sink (`rec`) – no desktop/system sounds in captures
- Optional loopback for monitoring (listen on/off)
- Track-accurate start/stop via MPRIS
- FLAC or MP3 output
- Automatic tagging from metadata
- Duplicate protection
- Clean setup/teardown
- CLI status (SSH-friendly)

---

# Architecture

```
Player → PipeWire → rec sink → ffmpeg → files
            ↑
        trackrec run
```

---

# Installation

```
git clone https://github.com/ElHanko/trackrec.git
cd trackrec
./install.sh
source ~/.profile
```

Installs:
- ~/.local/bin (commands)
- ~/.local/lib/trackrec (app files)

---

# Usage

```
trackrec run spotify
```

Stop:
```
Ctrl+C
```

---

# Commands

| Command | Description |
|--------|------------|
| trackrec | TUI |
| trackrec run | record |
| trackrec stop | stop |
| trackrec status | status |
| trackrec normalize | normalize |
| trackrec enrich | metadata |
| trackrec listen on/off | monitor |
| trackrec uninstall | remove |

---

# Config

```
~/.config/trackrec/trackrec.conf
```

---

# Enrich (optional)

```
trackrec enrich recordings/ --write
```

---

# Uninstall

```
trackrec uninstall
```

---

# License

MIT
