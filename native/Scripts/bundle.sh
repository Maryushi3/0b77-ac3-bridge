#!/bin/sh
# Build AC3Bridge.app (menu-bar, LSUIElement) from SwiftPM output + bundle ffmpeg sidecar.
# Usage: Scripts/bundle.sh [configuration]  (default: release)
set -eu
cd "$(dirname "$0")/.."

CFG="${1:-release}"
APP="AC3Bridge.app"
BUILD=".build/$CFG"

swift build -c "$CFG"

# Fresh .app skeleton
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

BIN="$BUILD/AC3Bridge"
if [ ! -f "$BIN" ]; then
  # SwiftPM names binary dir differently on some toolchains; find it.
  BIN="$(find .build -name AC3Bridge -type f -path "*$CFG*" | head -1)"
fi
cp "$BIN" "$APP/Contents/MacOS/AC3Bridge"
chmod +x "$APP/Contents/MacOS/AC3Bridge"

# Info.plist (menu-bar only: no dock icon)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AC3Bridge</string>
  <key>CFBundleIdentifier</key><string>com.local.ac3bridge</string>
  <key>CFBundleName</key><string>AC3Bridge</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

# ffmpeg sidecar: NOT bundled — receivers `brew install ffmpeg`.
# The app looks up ffmpeg at runtime (bundled path skipped, then
# /opt/homebrew/bin, /usr/local/bin, PATH). Fail-fast with install hint.
if command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg found: $(command -v ffmpeg) (runtime dependency, not bundled)"
else
  echo "WARNING: no ffmpeg installed — 'brew install ffmpeg' before running."
fi

# Ad-hoc sign so it launches on other Macs without a re-sign step (still needs Right-click > Open).
codesign --force --deep --sign - "$APP" || echo "codesign failed (non-fatal for local use)"

echo "Built $APP"
