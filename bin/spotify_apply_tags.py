#!/usr/bin/env python3
import argparse
import base64
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from mutagen import File as MFile

SPOTIFY_ID_RE = re.compile(r"^[A-Za-z0-9]{22}$")


def eprint(*a, **kw):
    print(*a, file=sys.stderr, **kw)


def http_json(req: Request) -> Dict[str, Any]:
    with urlopen(req, timeout=30) as r:
        data = r.read()
    return json.loads(data.decode("utf-8", "replace"))


def read_spotify_url(path: str) -> Optional[str]:
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
    nu = normalize_spotify_url(u)
    if not nu:
        return None
    tid = nu.rstrip("/").split("/")[-1]
    return tid if tid and SPOTIFY_ID_RE.match(tid) else None


def spotify_get_token(client_id: str, client_secret: str) -> Tuple[str, int]:
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
    req = Request(
        f"https://api.spotify.com/v1/tracks/{track_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


def spotify_get_album(token: str, album_id: str) -> Dict[str, Any]:
    req = Request(
        f"https://api.spotify.com/v1/albums/{album_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


def spotify_get_artist(token: str, artist_id: str) -> Dict[str, Any]:
    req = Request(
        f"https://api.spotify.com/v1/artists/{artist_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


def spotify_get_audio_features(token: str, track_id: str) -> Dict[str, Any]:
    req = Request(
        f"https://api.spotify.com/v1/audio-features/{track_id}",
        method="GET",
        headers={"Authorization": f"Bearer {token}"},
    )
    return http_json(req)


def is_mp3(path: str, audio: Any) -> bool:
    if path.lower().endswith(".mp3"):
        return True
    name = (audio.__class__.__name__ or "").lower() if audio else ""
    return "mp3" in name or "mpeg" in name


def set_tag_easy(audio: Any, key: str, value: str, force: bool, mp3_mode: bool) -> Tuple[bool, str]:
    """
    Returns (changed, used_key)
    For MP3: write as TXXX:<key> to avoid EasyID3 rejecting arbitrary keys.
    For FLAC/Vorbis: write as <key>.
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
    if not audio or audio.tags is None:
        return False

    cur = audio.tags.get(field)
    if cur and not force:
        return False

    audio.tags[field] = [value]
    return True


def enrich_one(
    path: str,
    token: str,
    force: bool,
    write: bool,
    set_year: bool,
    set_genre: bool,
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
            print(f"  Release: {release_date} ({release_prec or '?'})")

    audio = MFile(path, easy=True)
    if not audio:
        eprint(f"[err] mutagen could not open file for tagging: {path}")
        return False

    mp3_mode = is_mp3(path, audio)

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
    if set_year and release_date and len(release_date) >= 4:
        year = release_date[:4]
        std_writes.append(("date", release_date))
        std_writes.append(("year", year))

    if set_genre and artist_genres:
        std_writes.append(("genre", artist_genres[0]))

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", help="Audio file path(s)")
    ap.add_argument("--spotify-client-id", default=os.getenv("SPOTIFY_CLIENT_ID", ""))
    ap.add_argument("--spotify-client-secret", default=os.getenv("SPOTIFY_CLIENT_SECRET", ""))
    ap.add_argument("--write", action="store_true", help="Actually write tags (default: dry-run)")
    ap.add_argument("--force", action="store_true", help="Overwrite existing tags")
    ap.add_argument("--set-year", action="store_true", help="Also set standard year/date fields from album release_date")
    ap.add_argument("--set-genre", action="store_true", help="Also set standard genre (artist genres; weak signal)")
    ap.add_argument("--dump", action="store_true", help="Print fetched Spotify data (JSON)")
    ap.add_argument("--quiet", action="store_true", help="Less output (good for big batches)")
    args = ap.parse_args()

    cid = args.spotify_client_id.strip()
    csec = args.spotify_client_secret.strip()
    if not cid or not csec:
        eprint("Missing Spotify credentials. Set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET (env) or pass flags.")
        sys.exit(3)

    token, _expires = spotify_get_token(cid, csec)

    album_cache: Dict[str, Dict[str, Any]] = {}
    artist_cache: Dict[str, Dict[str, Any]] = {}
    af_cache: Dict[str, Dict[str, Any]] = {}

    ok = 0
    fail = 0
    for p in args.files:
        try:
            if enrich_one(
                p,
                token=token,
                force=args.force,
                write=args.write,
                set_year=args.set_year,
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
        except Exception as ex:
            eprint(f"[err] {ex} ({p})")
            fail += 1

    if not args.quiet:
        print(f"\nDone: ok={ok} fail={fail}")

    sys.exit(0 if fail == 0 else 1)


if __name__ == "__main__":
    main()
