# trackrec

Track-aware audio recorder for Linux using **PipeWire** and **MPRIS**.

`trackrec` records audio already being played locally, routes it through a dedicated PipeWire sink, and splits recordings per track using MPRIS playback events.

It is a **CLI-first**, transparent toolchain with no background services and no platform-specific APIs.

Recording and post-processing are intentionally separated: trackrec records locally; enrichment is optional and offline.

PipeWire • MPRIS • CLI-first • FLAC/MP3

---

# Features

* Dedicated recording sink (`rec`) – no desktop/system sounds in captures
* Optional loopback for monitoring (listen on/off)
* Track-accurate start/stop via MPRIS (`PlaybackStatus` + `Metadata`)
* **FLAC or MP3 output**
* Automatic tagging from MPRIS metadata (artist, title, album, track/disc numbers, source URL)
* Minimum-duration filter to drop junk clips
* Duplicate protection based on track URL
* Clean setup and teardown (no leftovers)
* Status inspection via CLI (also works over SSH)

---

# Architecture

trackrec routes audio streams through a dedicated PipeWire recording sink and splits recordings based on MPRIS playback events.

```text
Player → PipeWire stream → rec sink → ffmpeg → per-track files
           ↑
        trackrec-run
````

---

# Requirements

* Linux with **PipeWire** (and `pipewire-pulse`)
* `ffmpeg`
* Python ≥ 3.10
* Python packages:

  * `python3-dbus`
  * `python3-gi`

Install dependencies:

```bash
sudo apt install ffmpeg python3-dbus python3-gi
```

---

# Installation

Clone the repository and run the installer:

```bash
git clone https://github.com/ElHanko/trackrec.git
cd trackrec
./install.sh
source ~/.profile
```

This installs:

* command wrappers into:

```text
~/.local/bin
```

* and the actual trackrec files into:

```text
~/.local/bin/trackrec
```

The default installer **copies the files**, so the repository can be moved or deleted afterwards.

---

## Development mode

If you are working on the repository itself, you can install using symlinks instead:

```bash
./install.sh --link
```

This keeps the installed files under `~/.local/bin/trackrec` linked to the repository so changes take effect immediately.

---

## Optional: install metadata enrichment tools

```bash
./install.sh --with-enrich
```

This additionally installs:

* `trackrec-enrich`
* `spotify_apply_tags.py`

and creates a template file at:

```text
~/.config/trackrec/.env
```

---

# Quick Start

Start playback in your player (for example Spotify), then run:

```bash
trackrec-run spotify
```

Stop recording with:

```text
Ctrl+C
```

Your recordings will appear in:

```text
~/recordings
```

---

# Commands

| Command               | Description                              |
| --------------------- | ---------------------------------------- |
| `trackrec-run`        | start recording for a player             |
| `trackrec-status`     | show current recorder status             |
| `trackrec-stop`       | stop running recorder                    |
| `trackrec-listen-on`  | enable monitoring loopback               |
| `trackrec-listen-off` | disable monitoring                       |
| `trackrec-route`      | manually route streams to recording sink |
| `trackrec-setup`      | create recording sink and environment    |
| `trackrec-enrich`     | optional Spotify metadata enrichment     |
| `trackrec-uninstall`  | remove installed trackrec commands       |

---

# Configuration

Defaults are stored in:

```text
~/.config/trackrec/trackrec.conf
```

Example configuration:

```bash
TRACKREC_OUTDIR="$HOME/recordings"

TRACKREC_FORMAT="flac"
TRACKREC_COMP="5"
TRACKREC_MP3_BITRATE="320k"

TRACKREC_MIN_SECONDS="30"

TRACKREC_FOLLOW="1"
TRACKREC_FOLLOW_INTERVAL="1"

TRACKREC_LISTEN="0"
TRACKREC_DEDUPE="1"
```

CLI options always override these defaults.

---

# Usage

Start playback in any MPRIS-capable player, then run:

```bash
trackrec-run <pattern>
```

`<pattern>` matches the application stream name (case-insensitive).

Example:

```bash
trackrec-run spotify
```

Optional monitoring:

```bash
trackrec-run spotify --listen
```

Stop with `Ctrl+C` — routing and loopbacks are reverted automatically.

---

# Example Session

```text
$ trackrec-run spotify
Routing spotify → rec
REC -> recordings/Artist - Track.flac

$ trackrec-status
STATE=recording
ARTIST=Artist
TITLE=Track
```

---

# Output Format

Default recording format is **FLAC (lossless)**.

You can switch to MP3:

```bash
trackrec-run spotify --format mp3
```

Specify MP3 bitrate:

```bash
trackrec-run spotify --format mp3 --mp3-bitrate 320k
```

These options can also be set in `trackrec.conf`.

---

# Status & Monitoring

Check recorder status:

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

# Optional: metadata enrichment

After recording, you can optionally enrich files using `trackrec-enrich`.

This is a **separate batch step** and **not part of the real-time recording pipeline**.

---

## Install dependency

```bash
sudo apt install python3-mutagen
```

---

## Credentials via `.env`

Create a local `.env` file (do not commit it):

```env
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
```

`trackrec-enrich` loads `.env` automatically from:

* the project directory (`./.env`)
* or `~/.config/trackrec/.env`

Spotify credentials require a **Spotify Developer account** (client credentials flow).

---

## Run enrichment

Dry-run:

```bash
trackrec-enrich recordings/
```

Write tags:

```bash
trackrec-enrich recordings/ --write --set-year
```

If no path is given, `trackrec-enrich` uses the configured `TRACKREC_OUTDIR`.

---

# Uninstall

To remove all installed trackrec commands and files:

```bash
trackrec-uninstall
```

This removes:

* wrappers from `~/.local/bin`
* trackrec files from `~/.local/bin/trackrec`

Configuration files are **not removed automatically**:

```text
~/.config/trackrec
```

Remove them manually if you want a full wipe.

---

# Audio Notes

* Recording is taken from the local PipeWire graph
* Typical live setups run at **48 kHz**
* **FLAC preserves the captured signal losslessly**
* MP3 encoding uses the **libmp3lame encoder**

---

# Responsibility

This tool records **local audio output**.

Users are responsible for complying with the terms of service and applicable laws for any application they use it with.

---

# License

MIT

