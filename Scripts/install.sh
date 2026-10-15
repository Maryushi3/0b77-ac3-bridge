#!/bin/sh
# Install 0B77.app into /Applications and strip the quarantine flag, so
# Gatekeeper stops demanding Right-click → Open on every update.
# (Unsigned builds get quarantined on download; clearing the flag once per
# install is the whole trick. No paid signing involved.)
# Usage: Scripts/install.sh [path-to-0B77.app]  (default ./0B77.app)
set -eu
cd "$(dirname "$0")/.."
SRC="${1:-0B77.app}"

[ -d "$SRC" ] || { echo "Run Scripts/bundle.sh first"; exit 1; }
echo "Copying to /Applications (admin password needed)…"
sudo cp -R "$SRC" /Applications/0B77.app
xattr -dr com.apple.quarantine /Applications/0B77.app 2>/dev/null \
  || sudo xattr -dr com.apple.quarantine /Applications/0B77.app
echo "Installed — launch from Applications or Spotlight, no approval dance."
