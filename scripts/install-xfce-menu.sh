#!/usr/bin/env bash
set -euo pipefail

USER_HOME="${HOME}"

APP_DIR="$USER_HOME/.local/share/applications"
DIR_DIR="$USER_HOME/.local/share/desktop-directories"
MENU_DIR="$USER_HOME/.config/menus/applications-merged"
LAUNCHER_DIR="$USER_HOME/.local/bin/trackrec-launcher"

mkdir -p "$APP_DIR" "$DIR_DIR" "$MENU_DIR" "$LAUNCHER_DIR"

cat > "$DIR_DIR/trackrec.directory" <<'EOD'
[Desktop Entry]
Version=1.0
Type=Directory
Name=Trackrec
Comment=Trackrec tools
Icon=multimedia-volume-control
EOD

cat > "$MENU_DIR/trackrec.menu" <<'EOD'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<Menu>
  <Name>Applications</Name>

  <Menu>
    <Name>Multimedia</Name>

    <Menu>
      <Name>Trackrec</Name>
      <Directory>trackrec.directory</Directory>

      <Include>
        <Category>Trackrec</Category>
      </Include>
    </Menu>
  </Menu>
</Menu>
EOD

# -------------------------------
# Launcher scripts
# -------------------------------

cat > "$LAUNCHER_DIR/spotify-record.sh" <<'EOD'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/trackrec-run" spotify
EOD

cat > "$LAUNCHER_DIR/status-watch.sh" <<'EOD'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/trackrec-status" --watch
EOD

cat > "$LAUNCHER_DIR/enrich-recordings.sh" <<'EOD'
#!/usr/bin/env bash
set -euo pipefail

"$HOME/.local/bin/trackrec-enrich" --write --set-year --set-date --set-genre

rc=$?
echo
read -r -p "Press Enter to close..."
exit "$rc"
EOD

cat > "$LAUNCHER_DIR/stop.sh" <<'EOD'
#!/usr/bin/env bash
set -euo pipefail

"$HOME/.local/bin/trackrec-stop"

rc=$?
echo
read -r -p "Press Enter to close..."
exit "$rc"
EOD

cat > "$LAUNCHER_DIR/listen-on.sh" <<'EOD'
#!/usr/bin/env bash
set -euo pipefail

"$HOME/.local/bin/trackrec-listen-on"

rc=$?
echo
read -r -p "Press Enter to close..."
exit "$rc"
EOD

cat > "$LAUNCHER_DIR/listen-off.sh" <<'EOD'
#!/usr/bin/env bash
set -euo pipefail

"$HOME/.local/bin/trackrec-listen-off"

rc=$?
echo
read -r -p "Press Enter to close..."
exit "$rc"
EOD

chmod 755 \
  "$LAUNCHER_DIR/spotify-record.sh" \
  "$LAUNCHER_DIR/status-watch.sh" \
  "$LAUNCHER_DIR/enrich-recordings.sh" \
  "$LAUNCHER_DIR/stop.sh" \
  "$LAUNCHER_DIR/listen-on.sh" \
  "$LAUNCHER_DIR/listen-off.sh"

# -------------------------------
# Desktop entries
# -------------------------------

cat > "$APP_DIR/trackrec-spotify-record.desktop" <<EOD
[Desktop Entry]
Version=1.0
Type=Application
Name=Trackrec Spotify Record
Comment=Start recording Spotify with trackrec
Exec=$LAUNCHER_DIR/spotify-record.sh
Icon=media-record
Terminal=true
Categories=Trackrec;
EOD

cat > "$APP_DIR/trackrec-status-watch.desktop" <<EOD
[Desktop Entry]
Version=1.0
Type=Application
Name=Trackrec Status Watch
Comment=Watch live trackrec status
Exec=$LAUNCHER_DIR/status-watch.sh
Icon=utilities-system-monitor
Terminal=true
Categories=Trackrec;
EOD

cat > "$APP_DIR/trackrec-enrich-recordings.desktop" <<EOD
[Desktop Entry]
Version=1.0
Type=Application
Name=Trackrec Enrich Recordings
Comment=Enrich recordings with Spotify metadata
Exec=$LAUNCHER_DIR/enrich-recordings.sh
Icon=media-tape
Terminal=true
Categories=Trackrec;
EOD

cat > "$APP_DIR/trackrec-stop.desktop" <<EOD
[Desktop Entry]
Version=1.0
Type=Application
Name=Trackrec Stop Recording
Comment=Stop running trackrec recorder
Exec=$LAUNCHER_DIR/stop.sh
Icon=media-playback-stop
Terminal=true
Categories=Trackrec;
EOD

cat > "$APP_DIR/trackrec-listen-on.desktop" <<EOD
[Desktop Entry]
Version=1.0
Type=Application
Name=Trackrec Monitoring On
Comment=Enable trackrec monitoring loopback
Exec=$LAUNCHER_DIR/listen-on.sh
Icon=audio-volume-high
Terminal=true
Categories=Trackrec;
EOD

cat > "$APP_DIR/trackrec-listen-off.desktop" <<EOD
[Desktop Entry]
Version=1.0
Type=Application
Name=Trackrec Monitoring Off
Comment=Disable trackrec monitoring loopback
Exec=$LAUNCHER_DIR/listen-off.sh
Icon=audio-volume-muted
Terminal=true
Categories=Trackrec;
EOD

chmod 644 \
  "$APP_DIR/trackrec-spotify-record.desktop" \
  "$APP_DIR/trackrec-status-watch.desktop" \
  "$APP_DIR/trackrec-enrich-recordings.desktop" \
  "$APP_DIR/trackrec-stop.desktop" \
  "$APP_DIR/trackrec-listen-on.desktop" \
  "$APP_DIR/trackrec-listen-off.desktop" \
  "$DIR_DIR/trackrec.directory"

echo
echo "Trackrec XFCE menu installed."
echo
echo "Launcher scripts:"
echo "  $LAUNCHER_DIR"
echo
echo "Menu entries:"
echo "  $APP_DIR"
echo
echo "If duplicates were shown before, clear old cache with:"
echo "  rm -f ~/.cache/xfce4/desktop/menu-cache/*"
echo "Then reload:"
echo "  xfdesktop --reload"