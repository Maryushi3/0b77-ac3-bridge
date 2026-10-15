# Maintaining 0B77

Building, architecture decisions, and the release process. User docs live in
`README.md`.

## Layout

```
Package.swift            SwiftPM package (product 0B77, target ZeroB77 —
                         Swift ids can't start with a digit)
Sources/ZeroB77/         ZeroB77App (MenuBarExtra UI + controller),
                         AudioBridge (HAL IO, frame queue), EncoderProcess
                         (ffmpeg child), DeviceManager (CoreAudio enum),
                         BridgeSettings (UserDefaults), L10n (PL/EN strings),
                         MenuIcon (menu-bar grid)
Scripts/                 bundle.sh, make-dmg.sh, release.sh,
                         release-notes.sh, install-login-item.sh
Assets/0B77-master.png   icon master (1024); .icns is generated at bundle time
CHANGELOG.md             release notes source (`## [X.Y.Z]` sections)
```

No Xcode project — plain `swift build` with the CLT toolchain is enough.
Settings persist in UserDefaults (bundle id `moe.mary.0b77`).

## Decisions

- **BlackHole, not our own driver.** Six capturable channels need a virtual
  device; the alternative is a deprecated AudioServerPlugIn or a DriverKit
  system extension — a project of its own. Depending on BlackHole keeps this
  an app.
- **Homebrew ffmpeg at runtime, not bundled or linked.** The brew binary is a
  stub over Cellar dylibs (bundling = `@rpath` surgery per update);
  static-linking `libavcodec` saves ~5–15 ms of pipe jitter but buys a custom
  ffmpeg build, C-API churn and LGPL static-link duties. Revisit only if pipe
  latency shows up in measurements.
- **Shared output device.** No hog mode, no forced sample-rate/format changes
  — only warnings. The 18i20 keeps serving speakers (1–2) and system sounds.
- **Static encode, subprocess fallback.** `ThirdParty/` holds minimal static
  `libavcodec`/`libavformat`/`libavutil` (9.0.2, ac3 encoder + spdif muxer
  only — rebuild with `Scripts/build-ffmpeg.sh`). The app encodes in-process
  by default; `ZB77_SUBPROCESS=1` forces the old ffmpeg-child path.
  `Scripts/golden-test.sh` proves byte-identity between the two.
- **Unsigned distribution.** Ad-hoc signature, no notarization, no paid
  account — hence LaunchAgents instead of `SMAppService` for login items.
- **Update check, not auto-update.** The app polls the GitHub latest-release
  endpoint and offers a download link; installs stay manual. Full auto-update
  (Sparkle-style) is pointless unsigned: every replaced bundle re-triggers
  the Gatekeeper Right-click dance anyway, so "seamless" is unachievable
  without a paid account. Revisit only then.

## Build & release

```sh
swift build                    # sanity check
./Scripts/bundle.sh release    # 0B77.app; VERSION env bakes the plist version
./Scripts/make-dmg.sh 0.2.0    # DMG
./Scripts/release.sh 0.2.0     # above + annotated tag v0.2.0
```

CI (`macos-15`): every push/PR runs build + bundle + DMG smoke with the DMG
as artifact. Releases trigger **only** on strict `vX.Y.Z` tags — branch
pushes never ship. The release body comes from the matching `CHANGELOG.md`
section (write it under `## [Unreleased]` as you go); a missing section falls
back to generated notes.

## Backlog

Latency instrumentation vs the ~100 ms Python baseline, static `libavcodec`
link, Windows port (separate GUI, far future).
