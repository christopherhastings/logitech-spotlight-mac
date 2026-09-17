#!/bin/bash
# Runs the wire-format tests. No remote or receiver needed.
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
swiftc -O -framework IOKit \
  Sources/HIDPP.swift Sources/Spotlight.swift Sources/Settings.swift Sources/Actions.swift \
  Sources/Overlay.swift Sources/StatusFile.swift Sources/Controller.swift tools/tests/main.swift \
  -o "$OUT/tests"
"$OUT/tests"
