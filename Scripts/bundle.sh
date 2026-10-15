#!/bin/sh
# Build 0B77.app (menu-bar, LSUIElement) from SwiftPM output. Homebrew ffmpeg
# stays a runtime dependency (see FFmpegLocator).
# Usage: Scripts/bundle.sh [configuration]  (default: release)
set -eu
cd "$(dirname "$0")/.."

CFG="${1:-release}"
APP="0B77.app"
BUILD=".build/$CFG"

swift build -c "$CFG"

# Fresh .app skeleton
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN="$BUILD/0B77"
if [ ! -f "$BIN" ]; then
  # SwiftPM names binary dir differently on some toolchains; find it.
  BIN="$(find .build -name 0B77 -type f -path "*$CFG*" | head -1)"
fi
cp "$BIN" "$APP/Contents/MacOS/0B77"
chmod +x "$APP/Contents/MacOS/0B77"

# Info.plist (menu-bar only: no dock icon)
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>0B77</string>
  <key>CFBundleIdentifier</key><string>moe.mary.0b77</string>
  <key>CFBundleName</key><string>0B77</string>
  <key>CFBundleDisplayName</key><string>0B77</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>0B77</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSMicrophoneUsageDescription</key><string>0B77 captures 6-channel audio from the virtual input device (e.g. BlackHole) to encode it to AC-3. macOS requires microphone permission for any audio capture, including virtual devices.</string>
</dict>
</plist>
PLIST

# Icon: .iconset from the committed master, then .icns into Resources.
MASTER="Assets/0B77-master.png"
if [ -f "$MASTER" ] && command -v iconutil >/dev/null 2>&1; then
  rm -rf 0B77.iconset
  mkdir 0B77.iconset
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$MASTER" --out "0B77.iconset/icon_${sz}x${sz}.png" >/dev/null
    sips -z "$((sz * 2))" "$((sz * 2))" "$MASTER" --out "0B77.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns 0B77.iconset -o "$APP/Contents/Resources/0B77.icns"
  rm -rf 0B77.iconset
  echo "icon: $APP/Contents/Resources/0B77.icns"
else
  echo "WARNING: no icon master or iconutil — app ships without icon."
fi

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
