# 0B77

Menu-bar macOS app (name from the AC-3 sync word `0x0B77`). Captures 6-channel
audio from a virtual input device, encodes it to AC-3, wraps it in IEC 61937
(S/PDIF passthrough) and plays the result as 16-bit / 48 kHz on a chosen stereo
pair of an output device.

Concrete setup it was built for: BlackHole 16ch (5.1 on channels 1–6) as the
movie-audio source, Focusrite Scarlett 18i20 as output, channels 9–10 wired to
its S/PDIF out in Focusrite Control, channels 1–2 left alone for regular
speakers and system sounds.

Polish + English UI (header picker, follows the system locale by default).

## Requirements

- macOS 14+, Apple Silicon
- [BlackHole 16ch](https://github.com/ExistentialAudio/BlackHole) —
  `brew install blackhole-16ch`
- ffmpeg — `brew install ffmpeg` (runtime dependency, **not** bundled; see below)
- Microphone permission for 0B77 (System Settings → Privacy & Security →
  Microphone). macOS gates *all* audio capture behind it, including virtual
  devices like BlackHole. Without it the input is silent — the app requests it
  on first Start.

Audio MIDI Setup (do once):

- BlackHole 16ch: 48000 Hz, speakers configured as 5.1 (L R C LFE Ls Rs on
  channels 1–6 — this is most likely just the default 5.1 configuration).
  Set it as the system/movie-player output.
- Scarlett (or your DAC): 48000 Hz. System volume 100%.

## Why BlackHole

Something has to present the movie player's 5.1 as six capturable channels,
and on macOS that means a virtual audio device. The alternative — writing our
own — is an AudioServerPlugIn (deprecated) or a DriverKit system extension
(entitlements, user approvals, reboots, a project of its own). BlackHole is
the maintained, standard answer; depending on it keeps this project an app
instead of a driver project.

## Why ffmpeg from Homebrew (not bundled / not linked)

- A bundled `ffmpeg` binary looks self-contained until you check
  `otool -L`: the Homebrew build is a ~400 KB stub over ~7 Cellar dylibs.
  Shipping it means re-homing the whole dylib closure (`dylibbundler` +
  `@rpath` surgery) on every ffmpeg update, inside an unsigned bundle.
- Static-linking `libavcodec` is the "real" fix (no subprocess, no pipes,
  ~5–15 ms less jitter) but buys a custom minimal-ffmpeg build, C-API churn,
  and LGPL static-link obligations — for an app with three users.
- So: `brew install ffmpeg`, the app finds it at runtime
  (`/opt/homebrew/bin` → `/usr/local/bin` → `PATH`) and fails fast with the
  brew hint if it's missing. Revisit static linking only if pipe latency ever
  shows up in measurements.

## Build & run

```sh
cd native
swift build                    # CLI sanity check
./Scripts/bundle.sh release    # builds 0B77.app, ad-hoc signed
open 0B77.app                  # Right-click → Open on first launch (unsigned)
./Scripts/make-dmg.sh 0.2.0    # GitLab-Releases-ready DMG
```

No paid Apple Developer account is used: ad-hoc signature, no notarization.
Receivers drag to /Applications and Right-click → Open once.

## How it works

```
BlackHole 6ch → CoreAudio HAL IOProc → ffmpeg (s16le → ac3 → spdif)
            → HAL IOProc → output ch N/N+1, everything else silence
```

- `native/Sources/AC3Bridge/` — SwiftPM package (no Xcode project needed):
  `AC3BridgeApp.swift` (MenuBarExtra UI + controller), `AudioBridge.swift`
  (HAL input/output, frame queue mirroring the prototype's prefill/drop
  logic), `EncoderProcess.swift` (ffmpeg child), `DeviceManager.swift`
  (CoreAudio enumeration), `BridgeSettings.swift` (UserDefaults),
  `L10n.swift` (all PL/EN strings, in code).
- Settings persist in UserDefaults; the old Python prototype used
  `~/.ac3bridge.json` (`git tag prototype-tk`, `ac3bridge.py` + `run.sh`
  still in tree for reference).

## Safeguards (shared-device use)

The output device stays shared with the system — no hog mode, no forced
sample-rate/format changes (only warnings to fix 48 kHz in Audio MIDI Setup).

- Start blocked when input == output, or the pair exceeds the channel count.
- Channels 1–2 (speakers) need a two-step confirm; encoded AC-3 there is
  full-scale noise.
- Silence until the first full AC-3 frame is buffered; zero-fill on underrun.
- Watchdog stops the bridge on device replug or sample-rate flip.
- UI locks device/channel/bitrate pickers while running; buffer stays
  live-tunable. Quitting always stops HAL + the ffmpeg child.

Guarding against *something else* playing on 9–10 is the operator's job.

## Status / backlog

Working: menubar app, streaming verified on-device (receiver locks, sound ok).
Ideas parked: latency instrumentation vs the ~100 ms Python baseline,
login-at-login via LaunchAgents, GitLab Release upload flow, static
`libavcodec` link, Windows port (separate GUI, far future).
