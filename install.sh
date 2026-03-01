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
  echo "ERROR: missing $BIN_SRC" >&2
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

is_yes() {
  local a="${1:-}"
  case "${a,,}" in y|yes|j|ja) return 0;; *) return 1;; esac
}

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

# --- .env for enrichment (Spotify credentials) ---
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<'ENV'
# trackrec-enrich credentials (optional)
# Fill these if you want to use trackrec-enrich with Spotify Web API.
# Keep this file private (chmod 600). Do NOT commit it.

SPOTIFY_CLIENT_ID=
SPOTIFY_CLIENT_SECRET=
ENV
  chmod 600 "$ENV_FILE" || true
  echo "Created template: $ENV_FILE"
else
  echo "Env file exists: $ENV_FILE"
fi

# Ask only if .env looks unconfigured (empty values)
needs_env_fill=0
if [[ -f "$ENV_FILE" ]]; then
  if grep -qE '^SPOTIFY_CLIENT_ID=$' "$ENV_FILE" && grep -qE '^SPOTIFY_CLIENT_SECRET=$' "$ENV_FILE"; then
    needs_env_fill=1
  fi
fi

if [[ "$needs_env_fill" -eq 1 ]]; then
  echo
  echo "Optional: fill $ENV_FILE now?"
  read -r -p "Enter SPOTIFY_CLIENT_ID/SECRET interactively? [y/N]: " ans || true
  if is_yes "${ans:-}"; then
    read -r -p "SPOTIFY_CLIENT_ID: " CID || true
    read -r -p "SPOTIFY_CLIENT_SECRET: " CSEC || true

    perl -i -pe 's/^SPOTIFY_CLIENT_ID=.*/SPOTIFY_CLIENT_ID='"${CID//\//\\/}"'/ if /^SPOTIFY_CLIENT_ID=/' "$ENV_FILE"
    perl -i -pe 's/^SPOTIFY_CLIENT_SECRET=.*/SPOTIFY_CLIENT_SECRET='"${CSEC//\//\\/}"'/ if /^SPOTIFY_CLIENT_SECRET=/' "$ENV_FILE"
    chmod 600 "$ENV_FILE" || true
    echo "Updated: $ENV_FILE"
  fi
fi

# ensure default recordings dir exists (trackrec-run will also mkdir -p OUTDIR)
mkdir -p "$HOME/recordings" || true

echo
echo "Done."
echo "Open a new login shell (or run: source ~/.profile) then test:"
echo "  trackrec-status"
echo "  trackrec-run spotify"
echo
echo "Edit defaults here:"
echo "  $CFG_FILE"
echo
echo "Optional (for enrichment) fill credentials here:"
echo "  $ENV_FILE"
