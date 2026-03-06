# Changelog

## v1.2.0

### Features
- Add MP3 recording support (`--format mp3`)
- Add configurable MP3 bitrate (`--mp3-bitrate`)
- Rename recorder from `mpris_flac_recorder.py` to `trackrec-recorder.py`

### Improvements
- Extend config defaults (`TRACKREC_FORMAT`, `TRACKREC_MP3_BITRATE`)
- Installer respects configured output directory
- `trackrec-enrich` defaults to `TRACKREC_OUTDIR` if no path is given

### Spotify API handling
- Retry/backoff for rate limiting (HTTP 429)
- Token refresh and retry on expired token (HTTP 401)

## v1.1.5
- Installer: respect `TRACKREC_OUTDIR` when creating output directory
- `trackrec-enrich`: default to `TRACKREC_OUTDIR` if no path is given
- `trackrec-enrich`: fail fast if no default recording directory exists
- Spotify enrichment: handle API rate limits (HTTP 429) with retry/backoff
- Spotify enrichment: refresh access token and retry once on HTTP 401
- Add project changelog

## v1.1.4
- Fix `trackrec-run` stream matching (robust property extraction)
- Fix initial routing check to avoid false “no matching audio stream” aborts

## v1.1.3
- Installer: make metadata enrichment optional (`./install.sh --with-enrich`)
- Update uninstall behavior accordingly

## v1.1.2
- Installer: create `~/.config/trackrec` defaults and `.env` template

## v1.1.1
- `trackrec-run`: support config-driven defaults (`~/.config/trackrec/trackrec.conf`)

## v1.0.0
- Initial public release
