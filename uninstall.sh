#!/usr/bin/env bash
set -euo pipefail

BIN_DST="$HOME/.local/bin"

for name in trackrec-run trackrec-status trackrec-stop trackrec-setup trackrec-route trackrec-listen-on trackrec-listen-off mpris_flac_recorder.py; do
  p="$BIN_DST/$name"
  if [[ -L "$p" ]]; then
    rm -f "$p"
    echo "Removed symlink: $p"
  elif [[ -e "$p" ]]; then
    echo "Skip (not a symlink): $p"
  fi
done

echo "Done."
