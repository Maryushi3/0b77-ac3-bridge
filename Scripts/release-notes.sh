#!/bin/sh
# Print the CHANGELOG.md section for a version (without the header).
# Exits 1 when missing — the release workflow then falls back to generated notes.
# Usage: Scripts/release-notes.sh <version>
set -eu
VER="${1:?usage: Scripts/release-notes.sh <version>}"
BODY="$(awk -v hdr="## [$VER]" '
  index($0, hdr) == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' CHANGELOG.md)"
BODY="$(printf '%s\n' "$BODY" | sed '/./,$!d')"
[ -n "$BODY" ] || exit 1
printf '%s\n' "$BODY"
