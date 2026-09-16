#!/bin/bash
# Removes Presenter and its plug-in trigger. Leaves your settings alone.
set -euo pipefail
AGENT="$HOME/Library/LaunchAgents/io.github.presenter-mac.plist"

launchctl bootout "gui/$(id -u)/io.github.presenter-mac" 2>/dev/null || true
pkill -f "Presenter.app/Contents/MacOS/Presenter" 2>/dev/null || true
rm -f "$AGENT"
rm -rf /Applications/Presenter.app

echo "Presenter removed. The remote goes back to plain forward/back, which never needed it."
echo "To forget your button mappings too:  defaults delete io.github.presenter-mac"
