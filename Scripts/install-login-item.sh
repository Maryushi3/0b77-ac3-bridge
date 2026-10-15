#!/bin/sh
# Manage the 0B77 login item through ~/Library/LaunchAgents.
# SMAppService would need real (paid) signing, so the classic plist does it —
# works fine unsigned/ad-hoc.
#
# Usage:
#   Scripts/install-login-item.sh [path-to-0B77.app]  # install (default /Applications/0B77.app)
#   Scripts/install-login-item.sh --uninstall         # remove again
#
# The app launches at login but never auto-starts the bridge: devices may not
# be up yet, and streaming onto a changed layout is what the watchdog is for.
set -eu
LABEL="moe.mary.0b77"
DIR="$HOME/Library/LaunchAgents"
PLIST="$DIR/$LABEL.plist"
UIDNUM="$(id -u)"

uninstall() {
  launchctl bootout "gui/$UIDNUM/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "login item removed"
}

if [ "${1:-}" = "--uninstall" ]; then uninstall; exit 0; fi

APP="${1:-/Applications/0B77.app}"
BIN="$APP/Contents/MacOS/0B77"
[ -x "$BIN" ] || {
  echo "ERROR: no executable at $BIN"
  echo "Copy 0B77.app there first (or pass its path explicitly)."
  exit 1
}

mkdir -p "$DIR" "$HOME/Library/Logs"
launchctl bootout "gui/$UIDNUM/$LABEL" 2>/dev/null || true
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/0B77.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/0B77.err.log</string>
</dict>
</plist>
PLIST
chmod 644 "$PLIST"
plutil -lint "$PLIST"
launchctl bootstrap "gui/$UIDNUM" "$PLIST"
echo "login item installed -> $BIN (starts at next login)"
