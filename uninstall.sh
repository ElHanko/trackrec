#!/usr/bin/env bash
set -euo pipefail

BIN_DST="$HOME/.local/bin"

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

ENRICH_TOOLS=(
  trackrec-enrich
  spotify_apply_tags.py
)

echo "Removing symlinks from $BIN_DST ..."
for name in "${CORE_TOOLS[@]}" "${ENRICH_TOOLS[@]}"; do
  rm -f "$BIN_DST/$name"
  echo "  -> removed $name"
done

echo
echo "Note: config files are left in place:"
echo "  ~/.config/trackrec/trackrec.conf"
echo "  ~/.config/trackrec/.env"
echo "Remove them manually if you want a full wipe."
