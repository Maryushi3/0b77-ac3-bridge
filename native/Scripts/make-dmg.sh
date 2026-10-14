#!/bin/sh
# Make a GitLab-Releases-ready DMG from AC3Bridge.app.
# Usage: Scripts/make-dmg.sh [version]  (default: 0.1.0)
set -eu
cd "$(dirname "$0")/.."
VER="${1:-0.1.0}"
DMG="AC3Bridge-$VER-macOS-arm64.dmg"

[ -d AC3Bridge.app ] || { echo "Run Scripts/bundle.sh first"; exit 1; }
rm -f "$DMG"
hdiutil create -volname "AC3Bridge $VER" -srcfolder AC3Bridge.app -ov -format UDZO "$DMG"
echo "Wrote $DMG — attach to a GitLab Release; receivers: drag to /Applications, then Right-click > Open once."
