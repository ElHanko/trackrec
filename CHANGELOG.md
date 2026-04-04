# Changelog

## v1.3.1

### Fixed
- restore TUI launch and internal tool resolution

## v1.3.0

### Added
- add automated release script and remove legacy changelog-based script
- add trackrec-tui launcher to xfce menu
- add minimal trackrec terminal interface
- skip duplicate tracks via delayed MPRIS Next
- add configurable recorder sample rate
- remove launcher scripts and desktop menu entries
- add trackrec-normalize DJ preset launcher
- add loudnorm presets for post-processing
- add configurable stream volume reset to 100 percent
- add optional XFCE menu installer
- add --dj option for bpm and initial key tags

### Changed
- add trackrec dispatcher and move install layout
- remove redundant inline keybinding footer
- resolve internal backend via script directory
- resolve internal helpers via script directory
- introduce internal Spotify backend behind trackrec-enrich
- add early skip for already enriched files
- add separate --set-year and --set-date options
- only expose user-facing commands via wrappers
- execute tagger wrapper directly
- add compact live view for --watch mode
- use recorder rename and improve status output
- use ~/.local/bin/trackrec with command wrappers

### Fixed
- initialize sample_rate in Recorder to avoid AttributeError
- correct PipeWire sample rate detection and interactive prompt output
- improve cleanup of menu files and add cache hint
- update help and uninstall entries for Spotify backend rename
- only request Spotify audio features when needed
- avoid duplicate XFCE menu entries by removing AudioVideo category
- improve Spotify backend warnings and DJ tag handling
- initialize mp3 mode before early skip check
- resolve internal backend path
- resolve internal recorder path
- reduce flicker in --watch mode by avoiding terminal reset

## v1.2.1

### Changed

- Installer now copies binaries into `~/.local/bin` by default instead of creating symlinks
- Added `--link` option to install using symlinks (useful for development)
- Renamed uninstall script to `trackrec-uninstall` and install it automatically
- Updated README with improved installation instructions, Quick Start, command overview and examples

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
