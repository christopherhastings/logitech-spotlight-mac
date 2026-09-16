#!/bin/bash
# Stops macOS showing "Keyboard Setup Assistant" for the Logitech remote.
#
# The receiver advertises a keyboard interface, so macOS wants to know its
# physical layout. A three-button remote has no layout to identify, so we answer
# the question once, up front: ANSI (type 40).
#
# The answer lives in a system preference file, which is why this needs an admin
# password. It writes one line per Logitech keyboard-class device and touches
# nothing else.
set -euo pipefail

PLIST=/Library/Preferences/com.apple.keyboardtype
ANSI=40

entries=$(ioreg -c IOHIDDevice -r -w0 | /usr/bin/python3 -c '
import sys, re
blocks = re.split(r"\+-o ", sys.stdin.read())
seen = set()
for b in blocks:
    if "\"Product\"" not in b:
        continue
    def g(k):
        m = re.search(r"\"%s\" = (?:\"([^\"]*)\"|(\S+))" % k, b)
        if not m:
            return None
        return m.group(1) if m.group(1) is not None else m.group(2)
    # Logitech, and presenting as a keyboard (usage page 1, usage 6).
    if g("VendorID") != "1133" or g("PrimaryUsagePage") != "1" or g("PrimaryUsage") != "6":
        continue
    key = "%s-%s-%s" % (g("ProductID"), g("VendorID"), g("CountryCode") or "0")
    if key not in seen:
        seen.add(key)
        print(key)
')

if [ -z "$entries" ]; then
  echo "No Logitech keyboard-class device attached — plug in the receiver (or connect"
  echo "the remote over Bluetooth) and run this again."
  exit 0
fi

echo "Telling macOS it already knows these devices' keyboard layout:"
for key in $entries; do echo "  $key"; done
echo
echo "This needs an admin password because it is a system setting."

for key in $entries; do
  sudo defaults write "$PLIST" keyboardtype -dict-add "$key" -int "$ANSI"
done
sudo chmod 644 "$PLIST.plist" 2>/dev/null || true

echo
echo "Done. The Keyboard Setup Assistant will not appear for this remote again."
echo "Current contents:"
plutil -p "$PLIST.plist" 2>/dev/null || true
