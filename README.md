# trackrec

Application-specific track recording via **PipeWire** and **MPRIS**.

`trackrec` records audio that is already being played locally, routes it through a dedicated PipeWire sink, and splits recordings per track using MPRIS playback events. It is a **CLI-first**, transparent toolchain with no background services and no platform-specific APIs.

Recording and post-processing are intentionally separated: trackrec records locally; enrichment is optional and offline.

---

## Features

- Dedicated recording sink (`rec`) – no desktop/system sounds in captures
- Optional loopback for monitoring (listen on/off)
- Track-accurate start/stop via MPRIS (`PlaybackStatus` + `Metadata`)
- Lossless FLAC output with tags (artist, title, album, track/disc numbers, source URL if available)
- Minimum-duration filter to drop junk clips
- Duplicate protection based on track URL
- Clean setup and teardown (no leftovers)
- Status inspection via CLI (also works over SSH)

---

## Requirements

- Linux with **PipeWire** (and `pipewire-pulse`)
- `ffmpeg`
- Python ≥ 3.10
- Python packages: `python3-dbus`, `python3-gi`

```bash
sudo apt install ffmpeg python3-dbus python3-gi
````

---

## Installation

Clone the repository and install user-local symlinks:

```bash
cd $HOME/trackrec
./install.sh
source ~/.profile
```

This installs the **core recording tools only**.

All commands are installed to `~/.local/bin`.

### Optional: install metadata enrichment tools

```bash
./install.sh --with-enrich
```

This additionally installs:

* `trackrec-enrich`
* `spotify_apply_tags.py`

and creates a template file at:

```
~/.config/trackrec/.env
```

---

## Usage

Start playback in any MPRIS-capable player, then:

```bash
trackrec-run <pattern>
```

`<pattern>` matches the application stream name (case-insensitive).

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

## Optional: metadata enrichment

After recording, you can optionally enrich files using `trackrec-enrich`.
This is a **separate batch step** and **not part of the real-time recording path**.

### Install dependency

```bash
sudo apt install python3-mutagen
```

### Credentials via .env (recommended)

Create a local `.env` file (do not commit it):

```env
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
```

`trackrec-enrich` loads `.env` automatically from:

* the project directory (`./.env`)
* or `~/.config/trackrec/.env`

Spotify credentials require a **Spotify Developer account** (client credentials flow).

### Run

```bash
# Dry-run (no writes)
trackrec-enrich recordings/

# Write tags
trackrec-enrich recordings/ --write --set-year
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

````
