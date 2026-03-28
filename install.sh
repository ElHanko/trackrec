#!/usr/bin/env bash
set -euo pipefail

WITH_ENRICH=0
LINK_MODE=0

for a in "${@:-}"; do
  case "$a" in
    --with-enrich) WITH_ENRICH=1;;
    --link) LINK_MODE=1;;
    -h|--help)
      cat <<'USAGE'
Usage:
  ./install.sh [--with-enrich] [--link]

Installs trackrec into ~/.local/bin with real files stored under:
  ~/.local/bin/trackrec/

Options:
--with-enrich     also install optional enrichment support for trackrec-enrich
                  and create ~/.config/trackrec/.env template.
  --link          link files from the repository instead of copying them
                  (useful for development)
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $a" >&2
      exit 2
      ;;
  esac
done

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$PROJECT_DIR/bin"
BIN_DST="$HOME/.local/bin"
APP_DIR="$BIN_DST/trackrec"
PROFILE="$HOME/.profile"

CFG_DIR="$HOME/.config/trackrec"
CFG_FILE="$CFG_DIR/trackrec.conf"
ENV_FILE="$CFG_DIR/.env"

[[ -d "$BIN_SRC" ]] || { echo "ERROR: missing $BIN_SRC" >&2; exit 1; }

mkdir -p "$BIN_DST"
mkdir -p "$APP_DIR"

# Core tools (always installed)
CORE_TOOLS=(
  trackrec-recorder.py
  trackrec-listen-off
  trackrec-listen-on
  trackrec-normalize
  trackrec-route
  trackrec-run
  trackrec-setup
  trackrec-status
  trackrec-stop
  trackrec-uninstall
)
WRAPPER_TOOLS=(
  trackrec-run
  trackrec-status
  trackrec-stop
  trackrec-setup
  trackrec-route
  trackrec-listen-on
  trackrec-listen-off
  trackrec-normalize
  trackrec-uninstall
)
# Optional tools (installed only with --with-enrich)
ENRICH_TOOLS=(
  trackrec-enrich
  trackrec-enrich-spot
  trackrec-enrich-spot.py
)

ALL_TOOLS=("${CORE_TOOLS[@]}")
if [[ "$WITH_ENRICH" -eq 1 ]]; then
  ALL_TOOLS+=("${ENRICH_TOOLS[@]}")
fi

if [[ "$LINK_MODE" -eq 1 ]]; then
  echo "Linking trackrec files into $APP_DIR ..."
else
  echo "Installing trackrec files into $APP_DIR ..."
fi

install_tool() {
  local name="$1"
  local src="$BIN_SRC/$name"
  local dst="$APP_DIR/$name"

  [[ -f "$src" ]] || { echo "ERROR: missing $src" >&2; exit 1; }

  if [[ "$LINK_MODE" -eq 1 ]]; then
    ln -sf "$src" "$dst"
  else
    install -m 755 "$src" "$dst"
  fi

  echo "  -> $name"
}

create_wrapper() {
  local name="$1"
  local wrapper="$BIN_DST/$name"

  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
exec "\$HOME/.local/bin/trackrec/$name" "\$@"
EOF
  chmod 755 "$wrapper"
}

detect_sample_rate() {
  local rate=""

  if command -v pw-metadata >/dev/null 2>&1; then
    rate="$(pw-metadata -n settings 0 2>/dev/null | awk '
      /clock.rate/ {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9]+$/) {
            print $i
            exit
          }
        }
      }'
    )"
  fi

  case "$rate" in
    44100|48000)
      printf '%s\n' "$rate"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

choose_sample_rate() {
  local detected="$1"
  local choice=""

  echo
  echo "Select trackrec sample rate:"

  if [[ -n "$detected" ]]; then
    echo "  1) detected system rate: $detected Hz"
    echo "  2) 44100 Hz"
    echo "  3) 48000 Hz"
    read -r -p "Choice [1-3] (default: 1): " choice
    case "${choice:-1}" in
      1) printf '%s\n' "$detected" ;;
      2) printf '%s\n' "44100" ;;
      3) printf '%s\n' "48000" ;;
      *)
        echo "Invalid choice, using detected rate: $detected Hz" >&2
        printf '%s\n' "$detected"
        ;;
    esac
  else
    echo "  1) 44100 Hz"
    echo "  2) 48000 Hz"
    read -r -p "Choice [1-2] (default: 1): " choice
    case "${choice:-1}" in
      1) printf '%s\n' "44100" ;;
      2) printf '%s\n' "48000" ;;
      *)
        echo "Invalid choice, using 44100 Hz" >&2
        printf '%s\n' "44100"
        ;;
    esac
  fi
}

for name in "${ALL_TOOLS[@]}"; do
  install_tool "$name"
done

if [[ "$WITH_ENRICH" -eq 1 ]]; then
  WRAPPER_TOOLS+=(trackrec-enrich)
fi

echo
echo "Creating command wrappers in $BIN_DST ..."
for name in "${WRAPPER_TOOLS[@]}"; do
  create_wrapper "$name"
  echo "  -> $name"
done

# Ensure ~/.local/bin is in PATH for login shells
if ! grep -q 'HOME/.local/bin' "$PROFILE" 2>/dev/null; then
  echo "Updating $PROFILE to include ~/.local/bin in PATH ..."
  cat >> "$PROFILE" <<'EOP'

# add user-local binaries
if [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
  esac
fi
EOP
else
  echo "$PROFILE already mentions ~/.local/bin"
fi

mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR" || true

echo
echo "Config directory: $CFG_DIR"

created_cfg=0

DETECTED_SAMPLE_RATE=""
INITIAL_SAMPLE_RATE="44100"

if DETECTED_SAMPLE_RATE="$(detect_sample_rate)"; then
  :
else
  DETECTED_SAMPLE_RATE=""
fi

NEED_SAMPLE_RATE_CHOICE=0

if [[ ! -f "$CFG_FILE" ]]; then
  NEED_SAMPLE_RATE_CHOICE=1
elif ! grep -q '^TRACKREC_SAMPLE_RATE=' "$CFG_FILE" 2>/dev/null; then
  NEED_SAMPLE_RATE_CHOICE=1
fi

if [[ "$NEED_SAMPLE_RATE_CHOICE" -eq 1 ]]; then
  if [[ -t 0 && -t 1 ]]; then
    INITIAL_SAMPLE_RATE="$(choose_sample_rate "$DETECTED_SAMPLE_RATE")"
  else
    if [[ "$DETECTED_SAMPLE_RATE" == "44100" || "$DETECTED_SAMPLE_RATE" == "48000" ]]; then
      INITIAL_SAMPLE_RATE="$DETECTED_SAMPLE_RATE"
    fi
  fi

  echo "Using initial sample rate: ${INITIAL_SAMPLE_RATE} Hz"
fi

if [[ ! -f "$CFG_FILE" ]]; then
  cat > "$CFG_FILE" <<CFG
# trackrec defaults (loaded by trackrec-run)
# CLI flags always override these values.

TRACKREC_OUTDIR="$HOME/recordings"
TRACKREC_MIN_SECONDS="30"

# Output format: flac or mp3
TRACKREC_FORMAT="flac"

# FLAC compression level (only used with TRACKREC_FORMAT="flac")
TRACKREC_COMP="5"

# MP3 bitrate (only used with TRACKREC_FORMAT="mp3")
TRACKREC_MP3_BITRATE="320k"

TRACKREC_SAMPLE_RATE="$INITIAL_SAMPLE_RATE"

TRACKREC_LISTEN="0"

TRACKREC_FOLLOW="1"
TRACKREC_FOLLOW_INTERVAL="1"

# default ON (recommended)
TRACKREC_DEDUPE="1"

# force matched app stream volume to 100% before recording
# helps avoid accidental low-volume recordings caused by per-app volume changes
TRACKREC_FORCE_VOLUME="1"
CFG
  chmod 600 "$CFG_FILE" || true
  created_cfg=1
  echo "Created defaults: $CFG_FILE"
else
  echo "Defaults exist: $CFG_FILE"
fi

# Backfill newer config keys into existing configs without overwriting user values
if ! grep -q '^TRACKREC_FORCE_VOLUME=' "$CFG_FILE" 2>/dev/null; then
  cat >> "$CFG_FILE" <<'CFG'

# force matched app stream volume to 100% before recording
# helps avoid accidental low-volume recordings caused by per-app volume changes
TRACKREC_FORCE_VOLUME="1"
CFG
  echo "Added missing default: TRACKREC_FORCE_VOLUME=\"1\""
fi

if ! grep -q '^TRACKREC_SAMPLE_RATE=' "$CFG_FILE" 2>/dev/null; then
  cat >> "$CFG_FILE" <<CFG

# capture sample rate in Hz
# valid values: 44100 or 48000
TRACKREC_SAMPLE_RATE="$INITIAL_SAMPLE_RATE"
CFG
  echo "Added missing default: TRACKREC_SAMPLE_RATE=\"$INITIAL_SAMPLE_RATE\""
fi

# Create output directory:
# - if config was just created, use the default
# - otherwise respect configured TRACKREC_OUTDIR
if [[ "$created_cfg" -eq 1 ]]; then
  mkdir -p "$HOME/recordings" || true
else
  outdir="$(grep -E '^TRACKREC_OUTDIR=' "$CFG_FILE" | head -n1 | cut -d= -f2- | sed 's/^"//;s/"$//')"
  outdir="${outdir/#\~/$HOME}"
  outdir="${outdir//\$HOME/$HOME}"
  [[ -n "$outdir" ]] && mkdir -p "$outdir" || true
fi

# Optional enrichment support (.env template)
if [[ "$WITH_ENRICH" -eq 1 ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'ENV'
# trackrec-enrich credentials (optional)
# Requires Spotify Developer credentials (client credentials flow).
# Create an app in your Spotify Developer dashboard and paste the values below.
# Keep this file private (chmod 600). Do NOT commit it.

SPOTIFY_CLIENT_ID=
SPOTIFY_CLIENT_SECRET=
ENV
    chmod 600 "$ENV_FILE" || true
    echo "Created enrichment .env template: $ENV_FILE"
  else
    echo "Enrichment .env exists: $ENV_FILE"
  fi

  cat <<'NOTE'

Enrichment is OPTIONAL and not part of the recording pipeline.

To use:
  1) Install dependency:
       sudo apt install python3-mutagen
  2) Create Spotify Developer credentials (client id/secret)
  3) Fill:
       ~/.config/trackrec/.env
  4) Run:
       trackrec-enrich [<recordings-dir>] --write

NOTE
else
  cat <<'NOTE'

Optional enrichment (not installed by default):
  ./install.sh --with-enrich

Requires:
  - sudo apt install python3-mutagen
  - Spotify Developer credentials (client id/secret)

NOTE
fi

echo
echo "Done."
echo "Open a new login shell (or run: source ~/.profile) then test:"
echo "  trackrec-status"
echo "  trackrec-run spotify"
echo
echo "Installed files:"
echo "  $APP_DIR"
echo
echo "Edit defaults here:"
echo "  $CFG_FILE"
echo
echo "To uninstall later run:"
echo "  trackrec-uninstall"