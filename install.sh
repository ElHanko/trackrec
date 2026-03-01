#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$PROJECT_DIR/bin"
BIN_DST="$HOME/.local/bin"
PROFILE="$HOME/.profile"

CFG_DIR="$HOME/.config/trackrec"
CFG_FILE="$CFG_DIR/trackrec.conf"
ENV_FILE="$CFG_DIR/.env"

if [[ ! -d "$BIN_SRC" ]]; then
  echo "ERROR: missing $BIN_SRC"
  exit 1
fi

mkdir -p "$BIN_DST"

echo "Linking tools into $BIN_DST ..."
for f in "$BIN_SRC"/*; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  ln -sf "$f" "$BIN_DST/$name"
  chmod +x "$f" || true
  echo "  -> $name"
done

# Ensure ~/.local/bin is in PATH for login shells (SSH!)
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

is_yes() {
  local a="${1:-}"
  case "${a,,}" in y|yes|j|ja) return 0;; *) return 1;; esac
}

prompt() {
  local var="$1" default="$2" text="$3"
  local val
  read -r -p "$text [$default]: " val || true
  val="${val:-$default}"
  printf -v "$var" '%s' "$val"
}

echo
echo "Config directory: $CFG_DIR"

# --- trackrec.conf (defaults for trackrec-run) ---
if [[ ! -f "$CFG_FILE" ]]; then
  echo "No config found: $CFG_FILE"
  echo "Create defaults now? (recommended)"
  read -r -p "Create $CFG_FILE? [Y/n]: " ans || true
  if ! [[ "${ans:-Y}" =~ ^([Nn]|no|NO)$ ]]; then
    # sensible defaults (you asked for these)
    DEF_OUTDIR="$HOME/recordings"
    DEF_MIN_SECONDS="30"
    DEF_COMP="5"
    DEF_LISTEN="0"
    DEF_FOLLOW="1"
    DEF_FOLLOW_INTERVAL="1"
    DEF_DEDUPE="1"

    echo
    echo "Configure trackrec-run defaults (you can edit later: $CFG_FILE)"
    prompt OUTDIR "$DEF_OUTDIR" "Default output directory"
    prompt MIN_SECONDS "$DEF_MIN_SECONDS" "Drop recordings shorter than (seconds)"
    prompt COMP "$DEF_COMP" "FLAC compression level (0-8)"
    prompt LISTEN "$DEF_LISTEN" "Default listen mode (0=off, 1=on)"
    prompt FOLLOW "$DEF_FOLLOW" "Auto-follow new streams (0=off, 1=on)"
    prompt FOLLOW_INTERVAL "$DEF_FOLLOW_INTERVAL" "Follow interval (seconds)"
    prompt DEDUPE "$DEF_DEDUPE" "Dedupe by SPOTIFY_URL (0=off, 1=on)"

    cat > "$CFG_FILE" <<CFG
# trackrec configuration
# Loaded by trackrec-run (and only affects defaults; CLI flags still override)

TRACKREC_OUTDIR="$OUTDIR"
TRACKREC_MIN_SECONDS="$MIN_SECONDS"
TRACKREC_COMP="$COMP"
TRACKREC_LISTEN="$LISTEN"

TRACKREC_FOLLOW="$FOLLOW"
TRACKREC_FOLLOW_INTERVAL="$FOLLOW_INTERVAL"

# default ON (recommended)
TRACKREC_DEDUPE="$DEDUPE"
CFG

    chmod 600 "$CFG_FILE" || true
    echo "Wrote: $CFG_FILE"
  else
    echo "Skipped config creation."
  fi
else
  echo "Config exists: $CFG_FILE"
fi

# --- .env for enrichment (Spotify credentials) ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo
  echo "Optional: create $ENV_FILE for trackrec-enrich (Spotify API credentials)."
  read -r -p "Create $ENV_FILE now? [y/N]: " ans || true
  if is_yes "${ans:-}"; then
    read -r -p "SPOTIFY_CLIENT_ID: " CID || true
    read -r -p "SPOTIFY_CLIENT_SECRET: " CSEC || true

    cat > "$ENV_FILE" <<ENV
# trackrec enrichment credentials (do not commit)
SPOTIFY_CLIENT_ID=${CID:-}
SPOTIFY_CLIENT_SECRET=${CSEC:-}
ENV
    chmod 600 "$ENV_FILE" || true
    echo "Wrote: $ENV_FILE (chmod 600)"
  else
    echo "Skipped .env creation."
  fi
else
  echo "Env file exists: $ENV_FILE"
fi

# default recordings dir (legacy fallback)
mkdir -p "$HOME/recordings"

echo
echo "Done."
echo "Open a new shell (or run: source ~/.profile) then test:"
echo "  trackrec-status"
echo "  trackrec-run spotify"
echo
echo "Config:"
echo "  $CFG_FILE"
echo "  $ENV_FILE (optional, for enrichment)"
