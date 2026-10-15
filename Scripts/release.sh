#!/bin/sh
# Cut a 0B77 release: clean-tree check, bundle, DMG, annotated tag.
# Publishes via `gh` when available; otherwise prints the manual steps.
# Usage: Scripts/release.sh <version>   (e.g. Scripts/release.sh 0.2.0)
set -eu
cd "$(dirname "$0")/.."
VER="${1:?usage: Scripts/release.sh <version>}"
TAG="v$VER"
DMG="0B77-$VER-macOS-arm64.dmg"

[ -z "$(git status --porcelain)" ] || {
  echo "ERROR: tree not clean — commit first"; exit 1
}

./Scripts/bundle.sh release
./Scripts/make-dmg.sh "$VER"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag $TAG already exists — reusing"
else
  git tag -a "$TAG" -m "0B77 $VER"
  echo "tagged $TAG"
fi

if command -v gh >/dev/null 2>&1; then
  git push origin main "$TAG"
  gh release create "$TAG" "$DMG" --title "0B77 $VER" --generate-notes
  echo "published: $(gh release view "$TAG" --json url -q .url)"
else
  echo "gh not installed — publish with:"
  echo "  git push origin main $TAG"
  echo "  gh release create $TAG $DMG --title \"0B77 $VER\" --generate-notes"
  echo "or upload $PWD/$DMG to the $TAG release on github.com (needs: brew install gh + gh auth login)"
fi
