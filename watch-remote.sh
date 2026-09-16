#!/bin/bash
# Polls the receiver until the remote wakes up, then prints its details and
# every button / motion event. Ctrl-C to stop.
cd "$(dirname "$0")"
pkill -f "Presenter.app/Contents/MacOS/Presenter" 2>/dev/null
echo "Waiting for the remote… switch it on or press a button."
while true; do
  if ./tools/capture-remote 2>&1 | tee /dev/stderr | grep -q "^Device :"; then
    break
  fi
  sleep 2
done
