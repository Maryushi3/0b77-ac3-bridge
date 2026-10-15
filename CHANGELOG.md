# Changelog

Release descriptions come from the section matching the tag. Write it when
you cut the release; if it's missing, GitHub auto-generates notes instead.

## [Unreleased]

## [0.1.2] - 2026-10-15

- Fix DMG background (path was relative to the startup disk, so Finder
  silently skipped the whole layout); layout errors are now logged

## [0.1.1] - 2026-10-15

- Drag-and-drop DMG installer (background art, Applications shortcut)
- Update check: notifies about newer GitHub releases, installs stay manual

## [0.1.0] - 2026-10-15 - first public release

First native release. Menu-bar app replacing the Python prototype:

- CoreAudio HAL capture (6ch BlackHole) → Homebrew ffmpeg AC-3/SPDIF →
  stereo pair on the 18i20 (ch 9–10), shared-device safe (no hog, no forced
  reconfiguration)
- Safeguards: same-device block, two-step confirm on ch 1–2, replug /
  sample-rate watchdog, silence-until-first-frame
- Mic-permission request (TCC gates even virtual inputs) + live input meter
- Polish + English UI, Z5500-themed EL-dot icon, live menu-bar grid
- Login item via LaunchAgents, unsigned DMG distribution
