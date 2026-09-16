#!/bin/bash
# Installs Presenter for the current user.
#   - app into /Applications
#   - a LaunchAgent that starts it whenever the Logitech receiver is plugged in
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="Presenter.app"
APP_DST="/Applications/Presenter.app"
AGENT="$HOME/Library/LaunchAgents/io.github.presenter-mac.plist"

[ -d "$APP_SRC" ] || { echo "Presenter.app is not next to this script. Run ./build.sh first."; exit 1; }

echo "Stopping any running copy…"
launchctl bootout "gui/$(id -u)/io.github.presenter-mac" 2>/dev/null || true
pkill -f "Presenter.app/Contents/MacOS/Presenter" 2>/dev/null || true
sleep 1

echo "Installing to $APP_DST …"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
# Copying can carry a quarantine flag; without this the first launch is blocked.
# xattr lost its recursive flag on recent macOS, hence find.
find "$APP_DST" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true

echo "Installing the plug-in trigger…"
mkdir -p "$HOME/Library/LaunchAgents"
cp dist/io.github.presenter-mac.plist "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl load "$AGENT" 2>/dev/null || true

# The receiver announces a keyboard, so macOS pops its Keyboard Setup Assistant
# on a machine that has not seen this remote before. Answer it once, up front.
if [ -t 0 ]; then
  echo
  echo "One optional step: stop macOS asking about this remote's keyboard layout."
  read -r -p "Do that now? It needs your admin password. [Y/n] " reply
  case "${reply:-Y}" in
    [Nn]*) echo "Skipped. If the Keyboard Setup Assistant appears, just click Quit." ;;
    *) ./dist/silence-keyboard-assistant.sh || echo "Skipped." ;;
  esac
  echo
fi

echo "Starting Presenter…"
# Let launchd start it, so there is exactly one copy and it is the one the
# plug-in trigger will manage.
launchctl kickstart "gui/$(id -u)/io.github.presenter-mac" 2>/dev/null || open "$APP_DST"

cat <<'DONE'

Installed.

  * Presenter is in /Applications and is running now (menu bar, top right).
  * From now on, plugging in the Logitech receiver starts it automatically.
  * The setup window will walk you through the one permission it needs.

Until Accessibility is granted, the app leaves the remote alone and forward/back
keep working the way they always did.

To remove it later, run ./uninstall.sh
DONE
