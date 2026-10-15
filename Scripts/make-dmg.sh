#!/bin/sh
# Make a GitHub-Release-ready DMG from 0B77.app.
# Usage: Scripts/make-dmg.sh [version]  (default: 0.1.0)
set -eu
cd "$(dirname "$0")/.."
VER="${1:-0.1.0}"
DMG="0B77-$VER-macOS-arm64.dmg"

[ -d 0B77.app ] || { echo "Run Scripts/bundle.sh first"; exit 1; }
rm -f "$DMG"
hdiutil create -volname "0B77 $VER" -srcfolder 0B77.app -ov -format UDZO "$DMG"
echo "Wrote $DMG — upload it to the v$VER GitHub Release; receivers need 'brew install ffmpeg'; drag to /Applications, then Right-click > Open once."
