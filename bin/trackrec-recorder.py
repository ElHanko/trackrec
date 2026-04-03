#!/usr/bin/env python3
import argparse
import os
import re
import signal
import subprocess
import time

from dbus.mainloop.glib import DBusGMainLoop
import dbus
from gi.repository import GLib


def sanitize(s: str) -> str:
    s = (s or "").strip()
    s = re.sub(r"[\/\\\:\*\?\"\<\>\|]+", "_", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:180] if s else "unknown"


def pick_mpris_player(bus, preferred: str | None):
    names = [n for n in bus.list_names() if n.startswith("org.mpris.MediaPlayer2.")]
    if not names:
        return None
    if preferred:
        if not preferred.startswith("org.mpris.MediaPlayer2."):
            preferred = "org.mpris.MediaPlayer2." + preferred
        if preferred in names:
            return preferred
    return sorted(names)[0]


def to_int_str(v) -> str:
    if v is None:
        return ""
    try:
        i = int(v)
        return str(i) if i > 0 else ""
    except Exception:
        return ""


class Recorder:
    def __init__(
        self,
        out_dir,
        source,
        preferred_player,
        comp_level,
        min_seconds,
        dedupe,
        out_format,
        mp3_bitrate,
        sample_rate,
        autoskip,
        autoskip_delay,
    ):
        self.out_dir = out_dir
        self.source = source
        self.preferred_player = preferred_player
        self.comp_level = comp_level
        self.min_seconds = min_seconds
        self.dedupe = dedupe
        self.out_format = out_format
        self.mp3_bitrate = mp3_bitrate
        self.sample_rate = sample_rate
        self.autoskip = bool(autoskip)
        self.autoskip_delay = autoskip_delay
        self.autoskip_pending = False
        self.autoskip_track_id = None

        self.bus = dbus.SessionBus()
        self.player_name = None
        self.props = None
        self.player = None

        self.proc = None
        self.current_path = None
        self.current_started_at = None
        self.current_track_id = None
        self.current_url = None

        self.playback_status = None
        self.pending = {}

        self.index_file = os.path.join(self.out_dir, ".spotify_index")
        self.seen_urls = set()
        if self.dedupe:
            self._load_index()

        self.state_dir = f"/run/user/{os.getuid()}/trackrec-run"
        self.status_file = os.path.join(self.state_dir, "recorder.status")
        os.makedirs(self.state_dir, exist_ok=True)
        self._write_status(
            STATE="idle",
            AUTOSKIP=("1" if self.autoskip else "0"),
            AUTOSKIP_DELAY=str(self.autoskip_delay),
            AUTOSKIP_PENDING="0",
        )

    def _write_status(self, **fields):
        try:
            data = {}

            if os.path.exists(self.status_file):
                with open(self.status_file, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.rstrip("\n")
                        if "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        data[k] = v

            for k, v in fields.items():
                data[k] = str(v)

            with open(self.status_file, "w", encoding="utf-8") as f:
                for k, v in data.items():
                    f.write(f"{k}={v}\n")
        except Exception:
            pass

    def _load_index(self):
        try:
            with open(self.index_file, "r", encoding="utf-8") as f:
                for line in f:
                    u = line.strip()
                    if u:
                        self.seen_urls.add(u)
        except FileNotFoundError:
            pass

    def _append_index(self, url: str):
        if not url:
            return
        self.seen_urls.add(url)
        try:
            with open(self.index_file, "a", encoding="utf-8") as f:
                f.write(url + "\n")
        except Exception as e:
            print(f"Warning: could not write index file '{self.index_file}': {e}")

    def connect_player(self):
        self.player_name = pick_mpris_player(self.bus, self.preferred_player)
        if not self.player_name:
            print("No MPRIS player found.")
            return False

        obj = self.bus.get_object(self.player_name, "/org/mpris/MediaPlayer2")
        self.props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
        self.player = dbus.Interface(obj, "org.mpris.MediaPlayer2.Player")

        self.bus.add_signal_receiver(
            self.on_properties_changed,
            signal_name="PropertiesChanged",
            dbus_interface="org.freedesktop.DBus.Properties",
            path="/org/mpris/MediaPlayer2",
        )

        print(f"Using MPRIS player: {self.player_name}")
        return True

    def get_playback_status(self):
        return str(self.props.Get("org.mpris.MediaPlayer2.Player", "PlaybackStatus"))

    def get_metadata(self):
        md = self.props.Get("org.mpris.MediaPlayer2.Player", "Metadata")

        artists = md.get("xesam:artist") or []
        artist = str(artists[0]) if artists else ""

        return {
            "trackid": str(md.get("mpris:trackid", "")),
            "artist": artist,
            "title": str(md.get("xesam:title", "")),
            "album": str(md.get("xesam:album", "")),
            "url": str(md.get("xesam:url", "")),
            "tracknumber": to_int_str(md.get("xesam:trackNumber")),
            "discnumber": to_int_str(md.get("xesam:discNumber")),
        }

    def unique_path(self, base):
        base = sanitize(base)
        ext = ".flac" if self.out_format == "flac" else ".mp3"
        path = os.path.join(self.out_dir, f"{base}{ext}")
        if not os.path.exists(path):
            return path
        i = 2
        while True:
            p = os.path.join(self.out_dir, f"{base} ({i}){ext}")
            if not os.path.exists(p):
                return p
            i += 1

    def _clear_autoskip(self):
        self.autoskip_pending = False
        self.autoskip_track_id = None

    def _autoskip_next(self):
        artist = self.pending.get("artist", "").strip() if isinstance(self.pending, dict) else ""
        title = self.pending.get("title", "").strip() if isinstance(self.pending, dict) else ""

        try:
            if not self.autoskip_pending:
                return False

            # do not skip if we already moved on to another track
            if self.current_track_id != self.autoskip_track_id:
                self._clear_autoskip()
                return False

            # do not skip if a new recording is already running
            if self.proc:
                self._clear_autoskip()
                return False

            print("AUTOSKIP -> Next")
            self.player.Next()
        except Exception as e:
            print(f"Warning: autoskip failed: {e}")
        finally:
            self._clear_autoskip()
            self._write_status(
                STATE="skipped",
                ARTIST=artist,
                TITLE=title,
                SPOTIFY_URL=self.current_url or "",
                LAST_RESULT="SKIP",
                LAST_DURATION="-",
                LAST_FILE="-",
                AUTOSKIP=("1" if self.autoskip else "0"),
                AUTOSKIP_DELAY=str(self.autoskip_delay),
                AUTOSKIP_PENDING="0",
            )

        return False

    def _schedule_autoskip(self, md):
        if not self.autoskip:
            return

        track_id = md.get("trackid") or None

        if self.autoskip_pending and self.autoskip_track_id == track_id:
            return

        self.autoskip_pending = True
        self.autoskip_track_id = track_id

        self._write_status(
            STATE="skipped",
            ARTIST=md.get("artist", "").strip(),
            TITLE=md.get("title", "").strip(),
            SPOTIFY_URL=md.get("url", "") or "",
            AUTOSKIP=("1" if self.autoskip else "0"),
            AUTOSKIP_DELAY=str(self.autoskip_delay),
            AUTOSKIP_PENDING="1",
        )

        delay = max(0, int(self.autoskip_delay))
        if delay == 0:
            self._autoskip_next()
            return

        print(f"AUTOSKIP scheduled in {delay}s")
        GLib.timeout_add_seconds(delay, self._autoskip_next)

    def _finalize(self):
        if not self.proc:
            return

        try:
            self.proc.send_signal(signal.SIGINT)
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        finally:
            self.proc = None

        kept = False
        dur = 0.0
        if self.current_path and self.current_started_at:
            dur = time.time() - self.current_started_at
            if dur < self.min_seconds:
                try:
                    os.remove(self.current_path)
                    print(f"DROP ({dur:.1f}s) -> {self.current_path}")
                except FileNotFoundError:
                    pass
            else:
                print(f"KEEP ({dur:.1f}s) -> {self.current_path}")
                kept = True

        if kept and self.dedupe and self.current_url:
            self._append_index(self.current_url)

        self._write_status(
            STATE="idle",
            LAST_RESULT=("KEEP" if kept else "DROP"),
            LAST_DURATION=f"{dur:.1f}",
            LAST_FILE=self.current_path or "",
            LAST_SPOTIFY_URL=self.current_url or "",
            AUTOSKIP=("1" if self.autoskip else "0"),
            AUTOSKIP_DELAY=str(self.autoskip_delay),
            AUTOSKIP_PENDING="0",
        )

        self.current_path = None
        self.current_started_at = None
        self.current_track_id = None
        self.current_url = None

    def _start(self, md):
        os.makedirs(self.out_dir, exist_ok=True)

        url = md.get("url") or ""

        if self.dedupe and url and url in self.seen_urls:
            artist = md.get("artist", "").strip()
            title = md.get("title", "").strip()
            print(f"SKIP duplicate (SPOTIFY_URL seen): {artist} - {title}")

            self._write_status(
                STATE="skipped",
                ARTIST=artist,
                TITLE=title,
                SPOTIFY_URL=url,
                LAST_RESULT="SKIP",
                LAST_DURATION="-",
                LAST_FILE="-",
                AUTOSKIP=("1" if self.autoskip else "0"),
                AUTOSKIP_DELAY=str(self.autoskip_delay),
                AUTOSKIP_PENDING="0",
            )

            self.current_track_id = md.get("trackid")
            self.current_url = url
            self._schedule_autoskip(md)
            return

        name = f"{md['artist']} - {md['title']}".strip(" -")
        out_path = self.unique_path(name)

        cmd = [
            "ffmpeg",
            "-hide_banner", "-loglevel", "error",
            "-ar", str(self.sample_rate),
            "-f", "pulse", "-i", self.source,
        ]

        if self.out_format == "flac":
            cmd += [
                "-acodec", "flac",
                "-compression_level", str(self.comp_level),
            ]
        elif self.out_format == "mp3":
            cmd += [
                "-acodec", "libmp3lame",
                "-b:a", self.mp3_bitrate,
            ]
        else:
            raise RuntimeError(f"Unsupported format: {self.out_format}")

        cmd += [
            "-metadata", f"ARTIST={md['artist']}",
            "-metadata", f"TITLE={md['title']}",
        ]

        if md["album"]:
            cmd += ["-metadata", f"ALBUM={md['album']}"]
        if md["url"]:
            cmd += ["-metadata", f"SPOTIFY_URL={md['url']}"]
        if md["tracknumber"]:
            cmd += ["-metadata", f"TRACKNUMBER={md['tracknumber']}"]
        if md["discnumber"]:
            cmd += ["-metadata", f"DISCNUMBER={md['discnumber']}"]

        cmd.append(out_path)

        print(f"REC -> {out_path}")
        self.proc = subprocess.Popen(cmd)
        self.current_path = out_path
        self.current_started_at = time.time()
        self.current_track_id = md["trackid"]
        self.current_url = url

        self._write_status(
            STATE="recording",
            ARTIST=md.get("artist", "").strip(),
            TITLE=md.get("title", "").strip(),
            FILE=out_path,
            STARTED_AT=int(self.current_started_at),
            SPOTIFY_URL=url,
            AUTOSKIP=("1" if self.autoskip else "0"),
            AUTOSKIP_DELAY=str(self.autoskip_delay),
            AUTOSKIP_PENDING="0",
        )

    def _ensure_started(self):
        if self.playback_status != "Playing" or self.proc:
            return

        md = self.pending
        if not md.get("title"):
            md = self.get_metadata()
            self.pending = md

        if md.get("title"):
            self._start(md)

    def on_properties_changed(self, interface, changed, invalidated):
        if interface != "org.mpris.MediaPlayer2.Player":
            return

        if "PlaybackStatus" in changed:
            self.playback_status = str(changed["PlaybackStatus"])
            if self.playback_status in ("Paused", "Stopped"):
                self._finalize()
            elif self.playback_status == "Playing":
                self._ensure_started()

        if "Metadata" in changed:
            md = self.get_metadata()

            if self.autoskip_pending and md.get("trackid") != self.autoskip_track_id:
                self._clear_autoskip()

            self.pending = md

            if self.playback_status != "Playing":
                return

            if not self.proc:
                self._ensure_started()
            elif md["trackid"] and md["trackid"] != self.current_track_id:
                self._finalize()
                self._start(md)

    def prime(self):
        os.makedirs(self.out_dir, exist_ok=True)

        self.playback_status = self.get_playback_status()
        self.pending = self.get_metadata()
        if self.playback_status == "Playing":
            self._ensure_started()

    def shutdown(self):
        self._finalize()


def main():
    ap = argparse.ArgumentParser(
        description="MPRIS (PlaybackStatus+Metadata) -> split recorder with FLAC/MP3 output, tags, no timestamp filenames, dedupe by SPOTIFY_URL, and status export for trackrec-status."
    )
    ap.add_argument("--out", default="./recordings", help="Output directory")
    ap.add_argument("--source", required=True, help="Pulse/PipeWire source, e.g. rec.monitor")
    ap.add_argument("--player", default=None, help="Preferred MPRIS player (e.g. spotify)")
    ap.add_argument("--comp", type=int, default=5, choices=range(0, 9), help="FLAC compression level 0..8")
    ap.add_argument("--format", default="flac", choices=("flac", "mp3"), help="Output format")
    ap.add_argument("--mp3-bitrate", default="320k", help="MP3 bitrate, e.g. 192k, 256k, 320k")
    ap.add_argument("--min-seconds", type=int, default=30, help="Drop recordings shorter than this")
    ap.add_argument("--dedupe", action="store_true", help="Skip recording if SPOTIFY_URL was already kept before (stored in <out>/.spotify_index)")
    ap.add_argument("--sample-rate", type=int, default=44100, choices=(44100, 48000), help="Capture sample rate in Hz")
    ap.add_argument("--autoskip", type=int, default=0, choices=(0, 1), help="Automatically skip duplicate tracks via MPRIS Next")
    ap.add_argument("--autoskip-delay", type=int, default=5, help="Delay in seconds before triggering autoskip")
    args = ap.parse_args()

    DBusGMainLoop(set_as_default=True)

    r = Recorder(
        args.out,
        args.source,
        args.player,
        args.comp,
        args.min_seconds,
        args.dedupe,
        args.format,
        args.mp3_bitrate,
        args.sample_rate,
        args.autoskip,
        args.autoskip_delay,
    )
    if not r.connect_player():
        raise SystemExit(2)

    r.prime()

    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    finally:
        r.shutdown()


if __name__ == "__main__":
    main()