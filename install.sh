#!/usr/bin/env bash
set -euo pipefail

WITH_ENRICH=0
for a in "${@:-}"; do
  case "$a" in
    --with-enrich) WITH_ENRICH=1;;
    -h|--help)
      cat <<'USAGE'
Usage:
  ./install.sh [--with-enrich]

Installs core trackrec tools into ~/.local/bin and sets up defaults.

Optional:
  --with-enrich   also installs optional enrichment tools (trackrec-enrich + spotify_apply_tags.py)
                  and creates ~/.config/trackrec/.env template.
                  Requires Spotify Developer credentials + python3-mutagen.
USAGE
      exit 0
      ;;
  esac
done

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$PROJECT_DIR/bin"
BIN_DST="$HOME/.local/bin"
PROFILE="$HOME/.profile"

CFG_DIR="$HOME/.config/trackrec"
CFG_FILE="$CFG_DIR/trackrec.conf"
ENV_FILE="$CFG_DIR/.env"

[[ -d "$BIN_SRC" ]] || { echo "ERROR: missing $BIN_SRC" >&2; exit 1; }

mkdir -p "$BIN_DST"

# Core tools (always installed)
CORE_TOOLS=(
  mpris_flac_recorder.py
  trackrec-listen-off
  trackrec-listen-on
  trackrec-route
  trackrec-run
  trackrec-setup
  trackrec-status
  trackrec-stop
)

# Optional tools (installed only with --with-enrich)
ENRICH_TOOLS=(
  trackrec-enrich
  spotify_apply_tags.py
)

echo "Linking tools into $BIN_DST ..."

for name in "${CORE_TOOLS[@]}"; do
  src="$BIN_SRC/$name"
  [[ -f "$src" ]] || { echo "ERROR: missing $src" >&2; exit 1; }
  ln -sf "$src" "$BIN_DST/$name"
  chmod +x "$src" || true
  echo "  -> $name"
done

if [[ "$WITH_ENRICH" -eq 1 ]]; then
  for name in "${ENRICH_TOOLS[@]}"; do
    src="$BIN_SRC/$name"
    [[ -f "$src" ]] || { echo "ERROR: missing $src" >&2; exit 1; }
    ln -sf "$src" "$BIN_DST/$name"
    chmod +x "$src" || true
    echo "  -> $name"
  done
fi

# Ensure ~/.local/bin is in PATH for login shells (SSH login shells load ~/.profile)
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

# --- trackrec.conf (defaults for trackrec-run) ---
if [[ ! -f "$CFG_FILE" ]]; then
  cat > "$CFG_FILE" <<'CFG'
# trackrec defaults (loaded by trackrec-run)
# CLI flags always override these values.

TRACKREC_OUTDIR="$HOME/recordings"
TRACKREC_MIN_SECONDS="30"
TRACKREC_COMP="5"
TRACKREC_LISTEN="0"

TRACKREC_FOLLOW="1"
TRACKREC_FOLLOW_INTERVAL="1"

# default ON (recommended)
TRACKREC_DEDUPE="1"
CFG
  chmod 600 "$CFG_FILE" || true
  echo "Created defaults: $CFG_FILE"
else
  echo "Defaults exist: $CFG_FILE"
fi

# ensure default recordings dir exists (trackrec-run will also mkdir -p OUTDIR)
mkdir -p "$HOME/recordings" || true

# --- Optional enrichment support (.env template) ---
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
       trackrec-enrich <recordings-dir> --write

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
echo "Edit defaults here:"
echo "  $CFG_FILE"
