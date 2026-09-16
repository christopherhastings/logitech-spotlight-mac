#!/bin/bash
# Builds a self-contained installer folder, ready to drop on a USB stick.
# Usage:  ./make-usb-installer.sh  [/Volumes/YOUR_STICK]
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-./Presenter Installer}"
[ -d "Presenter.app" ] || ./build.sh

STAGE="$OUT/Presenter Installer"
[ "${1:-}" = "" ] && STAGE="$OUT"

rm -rf "$STAGE"
mkdir -p "$STAGE/dist"

cp -R Presenter.app "$STAGE/"
cp dist/io.github.presenter-mac.plist "$STAGE/dist/"
cp dist/silence-keyboard-assistant.sh "$STAGE/dist/"
chmod +x "$STAGE/dist/silence-keyboard-assistant.sh"
cp install.sh uninstall.sh "$STAGE/"

cat > "$STAGE/Install Presenter.command" <<'CMD'
#!/bin/bash
cd "$(dirname "$0")"
clear
echo "Installing Presenter…"
echo
./install.sh
echo
echo "You can close this window."
CMD
chmod +x "$STAGE/Install Presenter.command" "$STAGE/install.sh" "$STAGE/uninstall.sh"

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
PRESENTER — Logitech Spotlight support for Mac
==============================================

Forward and back already work on any Mac with nothing installed.
This adds the rest: the spotlight, the magnifier, cursor control,
button remapping, a talk timer and the battery readout.

TO INSTALL
----------
1. Double-click  "Install Presenter.command"
2. If macOS says it cannot be opened, right-click it instead and
   choose Open, then click Open in the dialog.
3. A setup window appears. Follow the two steps in it.

AFTER THAT
----------
Plug in the Logitech receiver and Presenter starts on its own.
Look for the circle-and-hand icon in the menu bar, top right.

IF A "KEYBOARD SETUP ASSISTANT" WINDOW APPEARS
----------------------------------------------
That is macOS asking what layout this "keyboard" is. The remote has
three buttons and no layout, so it is safe to click Quit.
The installer offers to stop it appearing again.

THE ONE PERMISSION IT NEEDS
---------------------------
Accessibility. Without it the app does nothing to the remote and
forward/back keep working exactly as before. The setup window has
a button that takes you straight to the right settings page.

Screen Recording is optional and only used by the magnifier.

TO REMOVE IT
------------
Double-click "uninstall.sh", or run it from Terminal.
TXT

# Anything copied off a USB stick is not quarantined, but a stick that has been
# through a download at some point can be, so strip it here.
find "$STAGE" -exec xattr -c {} \; 2>/dev/null || true

echo "Installer folder ready:"
echo "  $STAGE"
du -sh "$STAGE"
echo
echo "Copy that whole folder onto a USB stick. On any Mac, double-click"
echo "\"Install Presenter.command\" inside it."
