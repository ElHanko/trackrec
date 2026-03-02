# Changelog

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
