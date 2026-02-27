#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$PROJECT_DIR/bin"
BIN_DST="$HOME/.local/bin"
PROFILE="$HOME/.profile"

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

mkdir -p "$HOME/recordings"

echo
echo "Done."
echo "Open a new shell (or run: source ~/.profile) then test:"
echo "  trackrec-status"
echo "  trackrec-run spotify"
