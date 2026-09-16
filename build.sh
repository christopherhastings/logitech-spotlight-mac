#!/bin/bash
# Builds Presenter.app. No Xcode project needed — just swiftc plus a bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Presenter.app"
BIN="$APP/Contents/MacOS/Presenter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Presenter</string>
  <key>CFBundleDisplayName</key><string>Presenter</string>
  <key>CFBundleIdentifier</key><string>io.github.presenter-mac</string>
  <key>CFBundleExecutable</key><string>Presenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local build</string>
</dict>
</plist>
PLIST

echo "compiling…"
swiftc -O \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework IOKit -framework ScreenCaptureKit -framework ApplicationServices \
  Sources/HIDPP.swift Sources/Spotlight.swift Sources/Settings.swift Sources/Actions.swift \
  Sources/Overlay.swift Sources/Controller.swift Sources/SettingsView.swift \
  Sources/StatusFile.swift Sources/SingleInstance.swift Sources/Onboarding.swift Sources/AppDelegate.swift Sources/main.swift \
  -o "$BIN"

# Ad-hoc signature with a stable identifier so macOS remembers the
# Accessibility / Screen Recording grants across rebuilds.
codesign --force --sign - --identifier io.github.presenter-mac "$APP"

echo "built $APP"
