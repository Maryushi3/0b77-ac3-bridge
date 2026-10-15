#!/bin/sh
# Styled drag-and-drop DMG: 0B77.app + /Applications symlink on a background.
# Layout (icon positions, window frame, background) is applied with Finder via
# osascript; if that fails (e.g. headless CI) the DMG still ships with the
# symlink + background, just without the arranged layout.
# Usage: Scripts/make-dmg.sh [version]  (default: 0.1.0)
set -eu
cd "$(dirname "$0")/.."
VER="${1:-0.1.0}"
DMG="0B77-$VER-macOS-arm64.dmg"
VOL="0B77 $VER"
WIN_W=660
WIN_H=420

[ -d 0B77.app ] || { echo "Run Scripts/bundle.sh first"; exit 1; }
[ -f Assets/background.png ] || { echo "Missing Assets/background.png"; exit 1; }

STAGE="$(mktemp -d)/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
cp -R 0B77.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Assets/background.png "$STAGE/.background/background.png"
[ -f "Assets/background@2x.png" ] && cp "Assets/background@2x.png" "$STAGE/.background/"

RW="$DMG.rw.dmg"
rm -f "$DMG" "$RW"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW "$RW" >/dev/null
MNT="/Volumes/$VOL"
hdiutil attach -readwrite -noverify -noautoopen "$RW" >/dev/null

if osascript <<OSA 2>"$STAGE/osascript.err"; then
tell application "Finder"
  set bgFile to file ".background:background.png" of disk "$VOL"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 100 + $WIN_W, 100 + $WIN_H + 60}
    tell icon view options of container window
      set arrangement to not arranged
      set icon size to 128
      set background picture to bgFile
    end tell
    set position of item "0B77.app" to {150, 250}
    set position of item "Applications" to {510, 250}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
  echo "layout applied"
else
  echo "WARNING: Finder layout failed — shipping functional DMG without arrangement"
  cat "$STAGE/osascript.err" 2>/dev/null || true
fi

hdiutil detach "$MNT" >/dev/null
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"
echo "Wrote $DMG — upload it to the v$VER GitHub Release; receivers need 'brew install ffmpeg'; drag to /Applications, then Right-click > Open once."
