<img src="Assets/0B77-master.png" width="128" alt="0B77 icon — the AC-3 sync word as cyan EL dots">

# 0B77

*Bitstream, bridged.*

Menu-bar macOS app that plays movie surround sound through your S/PDIF-fed
receiver. It captures 6-channel audio from a virtual input, encodes it to AC-3
on the fly, and puts the result on a chosen stereo pair of your output device.

## You need

- macOS 14+, Apple Silicon
- [BlackHole 16ch](https://github.com/ExistentialAudio/BlackHole) —
  `brew install blackhole-16ch`
- ffmpeg — `brew install ffmpeg`
- Microphone permission for 0B77 (System Settings → Privacy & Security →
  Microphone). macOS demands it for *any* audio capture, even virtual cables.
  The app asks on first Start.

One-time setup in Audio MIDI Setup:

- BlackHole 16ch: 48000 Hz, speakers as 5.1 (most likely the default) — then
  select it as your movie player's output.
- Your DAC: 48000 Hz, system volume 100%.

## Install

Drag `0B77.app` to /Applications, Right-click → Open once (unsigned build),
then optionally start it at login:

```sh
./Scripts/install-login-item.sh              # uses /Applications/0B77.app
./Scripts/install-login-item.sh --uninstall  # remove again
```

## Use

Pick input (your 6ch virtual device), output, and the channel pair carrying
the S/PDIF feed (e.g. 9–10 on an 18i20 whose mixer routes them to S/PDIF),
then start. The menu icon shows a dim dot grid when idle and a lit cyan grid
while streaming; the popover reports buffer fill, dropouts, and input level.

Safety rules the app enforces:

- Input and output can't be the same device.
- Channels 1–2 (your speakers) need a two-step confirm — encoded AC-3 there
  is full-scale noise.
- Unplugging a device or flipping a sample rate stops the bridge immediately;
  refresh, verify channels, start again.
- The output device stays shared with the system: nothing else gets muted or
  reconfigured. Keeping other apps off your S/PDIF pair is on you.

## No sound?

- Status shows `wej. cisza` / `in silent` → input is silent. Grant the
  microphone permission and play something into BlackHole.
- Receiver doesn't lock onto the stream → both devices must actually run at
  48 kHz (check Audio MIDI Setup, not just the app's warnings).
- Bridge stopped with an "audio device changed" message → replug or
  sample-rate flip; verify channels and start again.
