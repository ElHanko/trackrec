#!/usr/bin/env python3
"""
Read SPOTIFY_URL tags from local audio files, fetch metadata from the Spotify Web API,
and optionally write enriched tags back to the files.

Design goals:
- batch-friendly: fetch one token and reuse it for many files
- robust against rate limits (429) and token expiry (401)
- work with both FLAC/Vorbis-style freeform tags and MP3 TXXX tags
- keep write behavior conservative unless --force is used
"""

import argparse
import base64
import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from mutagen import File as MFile

# Spotify track IDs are always 22-character base62-ish strings.
SPOTIFY_ID_RE = re.compile(r"^[A-Za-z0-9]{22}$")

# Default HTTP behavior for Spotify API calls.
# These values can be overridden from the CLI in main().
HTTP_MAX_RETRIES = 6
HTTP_DEFAULT_SLEEP = 0.15
HTTP_BASE_BACKOFF = 1.0
HTTP_MAX_BACKOFF = 60.0


class SpotifyAuthError(RuntimeError):
    """Raised for refreshable Spotify auth failures (currently HTTP 401)."""
    pass


def eprint(*a, **kw):
    """Print to stderr instead of stdout."""
    print(*a, file=sys.stderr, **kw)


# ---------------------------------------------------------------------------
# HTTP / Spotify API helpers
# ---------------------------------------------------------------------------
#
# All Spotify API requests go through http_json(). This centralizes:
# - rate-limit handling (429 + Retry-After)
# - transient network retries
# - auth error signaling (401 -> refreshable, 403 -> not refreshable here)
#
# The small default_sleep is intentional. Even a tiny pacing delay can reduce
# the chance of hitting Spotify's rate limit during larger batch runs.
# ---------------------------------------------------------------------------

def http_json(
    req: Request,
    *,
    max_retries: int = HTTP_MAX_RETRIES,
    base_backoff: float = HTTP_BASE_BACKOFF,
    max_backoff: float = HTTP_MAX_BACKOFF,
    default_sleep: float = HTTP_DEFAULT_SLEEP,
) -> Dict[str, Any]:
    """
    Execute an HTTP request and return JSON.

    Behavior:
    - On 429: honor Retry-After if available, otherwise use exponential backoff.
    - On transient network errors: retry with backoff.
    - On 401: raise SpotifyAuthError so caller can refresh token.
    - On 403: raise normal RuntimeError (refreshing usually does not help).
    """
    attempt = 0
    backoff = base_backoff

    while True:
        try:
            with urlopen(req, timeout=30) as r:
                if default_sleep > 0:
                    time.sleep(default_sleep)
                data = r.read()
            return json.loads(data.decode("utf-8", "replace"))

        except HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8", "replace")
            except Exception:
                body = ""

            if e.code == 429:
                ra = e.headers.get("Retry-After")
                if ra:
                    try:
                        wait = float(ra)
                    except Exception:
                        wait = backoff
                else:
                    wait = backoff

                attempt += 1
                if attempt > max_retries:
                    raise RuntimeError(f"HTTP 429 Too Many Requests (retries exceeded). body={body[:200]}")

                wait = min(max_backoff, max(0.5, wait))
                eprint(f"[rate-limit] 429 Too Many Requests. sleeping {wait:.1f}s (attempt {attempt}/{max_retries})")
                time.sleep(wait)
                backoff = min(max_backoff, backoff * 2)
                continue

            if e.code == 401:
                raise SpotifyAuthError(f"HTTP 401 auth error. body={body[:200]}")

            # 403 is usually a permission / policy issue, not a stale-token issue.
            if e.code == 403:
                raise RuntimeError(f"HTTP 403 forbidden. body={body[:200]}")

            raise RuntimeError(f"HTTP {e.code} error. body={body[:200]}")

        except (URLError, TimeoutError) as e:
            attempt += 1
            if attempt > max_retries:
                raise RuntimeError(f"Network error (retries exceeded): {e}")
            wait = min(max_backoff, backoff)
            eprint(f"[net] {e}. sleeping {wait:.1f}s (attempt {attempt}/{max_retries})")
            time.sleep(wait)
            backoff = min(max_backoff, backoff * 2)
            continue


def spotify_get_token(client_id: str, client_secret: str) -> Tuple[str, int]:
    """
    Fetch a client-credentials token from Spotify.

    Returns:
        (access_token, expires_in_seconds)
    """
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode("utf-8")).decode("ascii")
    req = Request(
        "https://accounts.spotify.com/api/token",
        method="POST",
        data=b"grant_type=client_credentials",
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    j = http_json(req)
    token = j.get("access_token")
    expires = int(j.get("expires_in", 3600))
    if not token:
        raise RuntimeError(f"Spotify token missing in response: {j}")
    return str(token), expires


def spotify_get_track(token: str, track_id: str) -> Dict[str, Any]:
    """Fetch Spotify track metadata."""
    req = Request(
        f"https://api.spotify.com/v1/tracks/{track_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


def spotify_get_album(token: str, album_id: str) -> Dict[str, Any]:
    """Fetch Spotify album metadata."""
    req = Request(
        f"https://api.spotify.com/v1/albums/{album_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


def spotify_get_artist(token: str, artist_id: str) -> Dict[str, Any]:
    """Fetch Spotify artist metadata."""
    req = Request(
        f"https://api.spotify.com/v1/artists/{artist_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


def spotify_get_audio_features(token: str, track_id: str) -> Dict[str, Any]:
    """Fetch Spotify audio features for a track."""
    req = Request(
        f"https://api.spotify.com/v1/audio-features/{track_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


# ---------------------------------------------------------------------------
# Local tag / URL handling
# ---------------------------------------------------------------------------
#
# Recordings may contain multiple historical or format-specific variants of
# the Spotify URL tag. We accept several keys here so that enrichment keeps
# working even if older files used slightly different names.
# ---------------------------------------------------------------------------

def read_spotify_url(path: str) -> Optional[str]:
    """Read a Spotify URL tag from a local audio file, if present."""
    audio = MFile(path, easy=True)
    if not audio or not audio.tags:
        return None

    keys = ["SPOTIFY_URL", "spotify_url", "Spotify_URL", "SPOTIFYURL", "spotifyurl", "TXXX:SPOTIFY_URL"]
    for k in keys:
        if k in audio.tags and audio.tags[k]:
            v = str(audio.tags[k][0]).strip()
            return v or None

    for k in list(audio.tags.keys()):
        if str(k).lower() in ("spotify_url", "spotifyurl"):
            v = audio.tags.get(k)
            if v:
                return str(v[0]).strip() or None

    return None


def normalize_spotify_url(u: str) -> Optional[str]:
    """
    Normalize supported Spotify track URL formats to:
        https://open.spotify.com/track/<id>

    Accepts:
    - spotify:track:<id>
    - https://open.spotify.com/track/<id>
    """
    if not u:
        return None
    u = u.strip()

    if u.startswith("spotify:track:"):
        tid = u.split(":")[-1].strip()
        if SPOTIFY_ID_RE.match(tid):
            return f"https://open.spotify.com/track/{tid}"
        return None

    try:
        p = urlparse(u)
    except Exception:
        return None

    if not p.scheme or not p.netloc:
        return None

    path = (p.path or "").strip("/")
    parts = [x for x in path.split("/") if x]

    tid = None
    for i, part in enumerate(parts):
        if part == "track" and i + 1 < len(parts):
            tid = parts[i + 1]
            break

    if tid and SPOTIFY_ID_RE.match(tid):
        return f"https://open.spotify.com/track/{tid}"
    return None


def spotify_track_id_from_url(u: str) -> Optional[str]:
    """Extract the canonical Spotify track ID from a Spotify track URL."""
    nu = normalize_spotify_url(u)
    if not nu:
        return None
    tid = nu.rstrip("/").split("/")[-1]
    return tid if tid and SPOTIFY_ID_RE.match(tid) else None


# ---------------------------------------------------------------------------
# Tag writing helpers
# ---------------------------------------------------------------------------
#
# FLAC/Vorbis can store arbitrary freeform keys directly.
# MP3/EasyID3 cannot, so custom metadata must go into TXXX frames.
# ---------------------------------------------------------------------------

def is_mp3(path: str, audio: Any) -> bool:
    """Best-effort check whether the file/tag container should be treated as MP3."""
    if path.lower().endswith(".mp3"):
        return True
    name = (audio.__class__.__name__ or "").lower() if audio else ""
    return "mp3" in name or "mpeg" in name


def set_tag_easy(audio: Any, key: str, value: str, force: bool, mp3_mode: bool) -> Tuple[bool, str]:
    """
    Write a custom tag and return (changed, used_key).

    For MP3:
        write as TXXX:<key> to avoid EasyID3 rejecting arbitrary keys.
    For FLAC/Vorbis:
        write as <key>.
    """
    if not audio or audio.tags is None:
        return False, key

    used_key = f"TXXX:{key}" if mp3_mode else key

    cur = None
    try:
        cur = audio.tags.get(used_key)
    except Exception:
        cur = None

    if cur and not force:
        return False, used_key

    audio.tags[used_key] = [value]
    return True, used_key


def set_standard_field(audio: Any, field: str, value: str, force: bool) -> bool:
    """
    Write a normal tag field like year/date/genre.

    Existing values are preserved unless --force is used.
    """
    if not audio or audio.tags is None:
        return False

    cur = audio.tags.get(field)
    if cur and not force:
        return False

    audio.tags[field] = [value]
    return True

def get_tag_value(audio: Any, key: str, mp3_mode: bool) -> str:
    """Read a tag value from FLAC/Vorbis or MP3 TXXX storage."""
    if not audio or audio.tags is None:
        return ""

    used_key = f"TXXX:{key}" if mp3_mode else key

    try:
        val = audio.tags.get(used_key)
    except Exception:
        return ""

    if not val:
        return ""

    try:
        return str(val[0]).strip()
    except Exception:
        return ""

def spotify_key_to_initialkey(key: Any, mode: Any) -> str:
    """
    Convert Spotify audio_features key/mode to a standard musical key string
    suitable for the 'initialkey' tag, e.g.:
      key=9, mode=0 -> Am
      key=0, mode=1 -> C
    """
    try:
        key_i = int(key)
        mode_i = int(mode)
    except Exception:
        return ""

    key_names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    if key_i < 0 or key_i > 11:
        return ""

    out = key_names[key_i]
    if mode_i == 0:
        out += "m"
    elif mode_i != 1:
        return ""

    return out


def is_already_enriched(audio: Any, mp3_mode: bool) -> bool:
    """
    Return True if the file already looks fully enriched.

    We use a pragmatic completeness check:
    - core Spotify track metadata present
    - release date present
    - artist genres present
    - at least one audio feature present

    This lets us skip API calls entirely on later runs unless --force is used.
    """
    required_keys = [
        "SPOTIFY_TRACK_ID",
        "SPOTIFY_TITLE",
        "SPOTIFY_ARTIST",
        "SPOTIFY_ALBUM",
        "SPOTIFY_RELEASE_DATE",
        "SPOTIFY_ARTIST_GENRES",
        "SPOTIFY_AF_TEMPO",
    ]
    return all(get_tag_value(audio, key, mp3_mode) for key in required_keys)

# ---------------------------------------------------------------------------
# Per-file enrichment
# ---------------------------------------------------------------------------
#
# Flow:
# 1) read SPOTIFY_URL from local file tags
# 2) normalize URL and extract track ID
# 3) fetch Spotify track / album / artist / audio-features metadata
# 4) optionally dump metadata to stdout
# 5) optionally write enriched tags back to the file
#
# Caches are passed in from main() so large batch runs do not repeatedly fetch
# the same album / artist / audio-features data.
# ---------------------------------------------------------------------------

def enrich_one(
    path: str,
    token: str,
    force: bool,
    write: bool,
    set_year: bool,
    set_date: bool,
    set_genre: bool,
    dj: bool,
    dump: bool,
    quiet: bool,
    album_cache: Dict[str, Dict[str, Any]],
    artist_cache: Dict[str, Dict[str, Any]],
    af_cache: Dict[str, Dict[str, Any]],
) -> bool:
    su_raw = read_spotify_url(path)
    if not su_raw:
        if not quiet:
            eprint(f"[skip] No SPOTIFY_URL tag found in: {path}")
        return False

    su = normalize_spotify_url(su_raw)
    if not su:
        eprint(f"[skip] SPOTIFY_URL exists but is not a usable track URL: {su_raw} ({path})")
        return False

    tid = spotify_track_id_from_url(su)
    if not tid:
        eprint(f"[skip] Could not extract Spotify track id from URL: {su} ({path})")
        return False

    # Open local tags early so we can skip already-enriched files before making
    # any Spotify API requests.
    audio = MFile(path, easy=True)
    if not audio:
        eprint(f"[err] mutagen could not open file for tagging: {path}")
        return False

    mp3_mode = is_mp3(path, audio)

    if not force and is_already_enriched(audio, mp3_mode):
        if not quiet:
            print(f"[skip] Already fully enriched: {path}")
        return True

    track = spotify_get_track(token, tid)

    title = str(track.get("name") or "").strip()
    dur_ms = int(track.get("duration_ms") or 0)
    explicit = bool(track.get("explicit") or False)
    popularity = int(track.get("popularity") or 0)
    isrc = str(((track.get("external_ids") or {}).get("isrc")) or "").strip()
    disc_no = int(track.get("disc_number") or 0)
    track_no = int(track.get("track_number") or 0)

    artists = track.get("artists") or []
    artist0 = str((artists[0] or {}).get("name") or "").strip() if artists else ""
    artist0_id = str((artists[0] or {}).get("id") or "").strip() if artists else ""

    album_min = track.get("album") or {}
    album_id = str(album_min.get("id") or "").strip()
    album_name = str(album_min.get("name") or "").strip()

    if album_id and album_id in album_cache:
        album = album_cache[album_id]
    else:
        album = spotify_get_album(token, album_id) if album_id else {}
        if album_id:
            album_cache[album_id] = album

    release_date = str(album.get("release_date") or "").strip()
    release_prec = str(album.get("release_date_precision") or "").strip()
    upc = str(((album.get("external_ids") or {}).get("upc")) or "").strip()
    label = str(album.get("label") or "").strip()
    album_type = str(album.get("album_type") or "").strip()
    total_tracks = int(album.get("total_tracks") or 0)

    artist_genres: List[str] = []
    if artist0_id:
        if artist0_id in artist_cache:
            a = artist_cache[artist0_id]
            artist_genres = list(a.get("genres") or [])
        else:
            try:
                a = spotify_get_artist(token, artist0_id)
                artist_cache[artist0_id] = a
                artist_genres = list(a.get("genres") or [])
            except Exception:
                artist_genres = []

    if tid in af_cache:
        audio_features = af_cache[tid]
    else:
        try:
            audio_features = spotify_get_audio_features(token, tid) or {}
        except Exception:
            audio_features = {}
        af_cache[tid] = audio_features

    if dump:
        out = {
            "file": path,
            "spotify_url": su,
            "track_id": tid,
            "artist": artist0,
            "title": title,
            "duration_ms": dur_ms,
            "isrc": isrc,
            "explicit": explicit,
            "popularity": popularity,
            "disc_number": disc_no,
            "track_number": track_no,
            "album": {
                "id": album_id,
                "name": album_name,
                "release_date": release_date,
                "release_date_precision": release_prec,
                "upc": upc,
                "label": label,
                "album_type": album_type,
                "total_tracks": total_tracks,
            },
            "artist_genres": artist_genres,
            "audio_features": audio_features,
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))

    if not quiet:
        print(f"\nFile: {path}")
        print(f"Spotify URL: {su}")
        print("Spotify track:")
        print(f"  Artist: {artist0 or '-'}")
        print(f"  Title : {title or '-'}")
        print(f"  ISRC  : {isrc or '-'}")
        print(f"  DurMs : {dur_ms}")
        print(f"  Album : {album_name or '-'}")
        if release_date:
            # Hide "(day)" because a full date is already self-explanatory.
            if release_prec == "day":
                print(f"  Release: {release_date}")
            elif release_prec:
                print(f"  Release: {release_date} ({release_prec})")
            else:
                print(f"  Release: {release_date}")

    tags_to_write: Dict[str, str] = {
        "SPOTIFY_URL": su,
        "SPOTIFY_TRACK_ID": tid,
        "SPOTIFY_TITLE": title,
        "SPOTIFY_ARTIST": artist0,
        "SPOTIFY_ALBUM": album_name,
        "SPOTIFY_ALBUM_ID": album_id,
        "SPOTIFY_ISRC": isrc,
        "SPOTIFY_UPC": upc,
        "SPOTIFY_DURATION_MS": str(dur_ms),
        "SPOTIFY_EXPLICIT": "1" if explicit else "0",
        "SPOTIFY_POPULARITY": str(popularity),
        "SPOTIFY_DISC_NUMBER": str(disc_no),
        "SPOTIFY_TRACK_NUMBER": str(track_no),
        "SPOTIFY_RELEASE_DATE": release_date,
        "SPOTIFY_RELEASE_DATE_PRECISION": release_prec,
        "SPOTIFY_ALBUM_TYPE": album_type,
        "SPOTIFY_LABEL": label,
        "SPOTIFY_ALBUM_TOTAL_TRACKS": str(total_tracks),
        "SPOTIFY_ARTIST_GENRES": "; ".join(artist_genres),
    }

    af_map = {
        "danceability": "SPOTIFY_AF_DANCEABILITY",
        "energy": "SPOTIFY_AF_ENERGY",
        "key": "SPOTIFY_AF_KEY",
        "loudness": "SPOTIFY_AF_LOUDNESS",
        "mode": "SPOTIFY_AF_MODE",
        "speechiness": "SPOTIFY_AF_SPEECHINESS",
        "acousticness": "SPOTIFY_AF_ACOUSTICNESS",
        "instrumentalness": "SPOTIFY_AF_INSTRUMENTALNESS",
        "liveness": "SPOTIFY_AF_LIVENESS",
        "valence": "SPOTIFY_AF_VALENCE",
        "tempo": "SPOTIFY_AF_TEMPO",
        "time_signature": "SPOTIFY_AF_TIME_SIGNATURE",
    }
    for k, outk in af_map.items():
        if k in audio_features and audio_features[k] is not None:
            tags_to_write[outk] = str(audio_features[k])

    std_writes: List[Tuple[str, str]] = []

    if release_date:
        if set_date:
            std_writes.append(("date", release_date))

        if set_year and len(release_date) >= 4:
            year = release_date[:4]
            std_writes.append(("year", year))

    if set_genre and artist_genres:
        std_writes.append(("genre", artist_genres[0]))

    if dj:
        tempo = audio_features.get("tempo")
        if tempo is not None:
            try:
                std_writes.append(("bpm", str(round(float(tempo), 2))))
            except Exception:
                pass

        initialkey = spotify_key_to_initialkey(
            audio_features.get("key"),
            audio_features.get("mode"),
        )
        if initialkey:
            std_writes.append(("initialkey", initialkey))


    if not write:
        if not quiet:
            print("Dry-run only. Use --write to actually write.")
        return True

    changed = 0
    for k, v in tags_to_write.items():
        if not v:
            continue
        ch, _used_key = set_tag_easy(audio, k, v, force=force, mp3_mode=mp3_mode)
        if ch:
            changed += 1

    for f, v in std_writes:
        if set_standard_field(audio, f, v, force=force):
            changed += 1

    if changed == 0:
        if not quiet:
            print("No changes (everything already present, or --force not set).")
        return True

    try:
        audio.save()
    except Exception as ex:
        eprint(f"[err] ERROR writing tags: {ex} ({path})")
        return False

    if not quiet:
        print(f"Wrote {changed} tag(s).")
    return True


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
#
# One Spotify token is fetched and reused for the whole batch run.
# We refresh slightly before expiry to avoid edge cases during long runs.
# If a single file still triggers a 401, we refresh once and retry that file.
# ---------------------------------------------------------------------------

def main():
    global HTTP_MAX_RETRIES, HTTP_DEFAULT_SLEEP

    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", help="Audio file path(s)")
    ap.add_argument("--spotify-client-id", default=os.getenv("SPOTIFY_CLIENT_ID", ""))
    ap.add_argument("--spotify-client-secret", default=os.getenv("SPOTIFY_CLIENT_SECRET", ""))
    ap.add_argument("--write", action="store_true", help="Actually write tags (default: dry-run)")
    ap.add_argument("--force", action="store_true", help="Overwrite existing tags")
    ap.add_argument("--set-year", action="store_true", help="Set standard year field from album release_date")
    ap.add_argument("--set-date", action="store_true", help="Set standard date field from album release_date")
    ap.add_argument("--set-genre", action="store_true", help="Also set standard genre (artist genres; weak signal)")
    ap.add_argument("--dump", action="store_true", help="Print fetched Spotify data (JSON)")
    ap.add_argument("--dj", action="store_true", help="Also write DJ-friendly standard tags (bpm, initialkey)")
    ap.add_argument("--quiet", action="store_true", help="Less output (good for big batches)")
    ap.add_argument("--max-retries", type=int, default=6, help="Maximum retries for rate-limit/network errors")
    ap.add_argument("--sleep", type=float, default=0.15, help="Small pacing sleep between requests (seconds)")
    args = ap.parse_args()

    HTTP_MAX_RETRIES = args.max_retries
    HTTP_DEFAULT_SLEEP = args.sleep

    cid = args.spotify_client_id.strip()
    csec = args.spotify_client_secret.strip()
    if not cid or not csec:
        eprint("Missing Spotify credentials. Set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET (env) or pass flags.")
        sys.exit(3)

    token, expires = spotify_get_token(cid, csec)

    # Refresh slightly before actual expiry so we do not hit expiry mid-request
    # during longer batch runs.
    token_expires_at = time.time() + max(0, int(expires) - 60)

    album_cache: Dict[str, Dict[str, Any]] = {}
    artist_cache: Dict[str, Dict[str, Any]] = {}
    af_cache: Dict[str, Dict[str, Any]] = {}

    ok = 0
    fail = 0

    for p in args.files:
        if time.time() >= token_expires_at:
            if not args.quiet:
                eprint("[auth] token expired/near expiry, refreshing ...")
            token, expires = spotify_get_token(cid, csec)
            token_expires_at = time.time() + max(0, int(expires) - 60)

        try:
            if enrich_one(
                p,
                token=token,
                force=args.force,
                write=args.write,
                set_year=args.set_year,
                set_date=args.set_date,
                set_genre=args.set_genre,
                dj=args.dj,
                dump=args.dump,
                quiet=args.quiet,
                album_cache=album_cache,
                artist_cache=artist_cache,
                af_cache=af_cache,
            ):
                ok += 1
            else:
                fail += 1

        except SpotifyAuthError as ex:
            eprint(f"[auth] {ex} ({p})")
            eprint("[auth] refreshing token and retrying once ...")
            try:
                token, expires = spotify_get_token(cid, csec)
                token_expires_at = time.time() + max(0, int(expires) - 60)

                if enrich_one(
                    p,
                    token=token,
                    force=args.force,
                    write=args.write,
                    set_year=args.set_year,
                    set_date=args.set_date,
                    set_genre=args.set_genre,
                    dump=args.dump,
                    quiet=args.quiet,
                    album_cache=album_cache,
                    artist_cache=artist_cache,
                    af_cache=af_cache,
                ):
                    ok += 1
                else:
                    fail += 1

            except Exception as ex2:
                eprint(f"[err] {ex2} ({p})")
                fail += 1

        except Exception as ex:
            eprint(f"[err] {ex} ({p})")
            fail += 1

    if not args.quiet:
        print(f"\nDone: ok={ok} fail={fail}")

    sys.exit(0 if fail == 0 else 1)


if __name__ == "__main__":
    main()