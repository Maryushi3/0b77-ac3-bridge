#!/bin/sh
# Golden test: static encoder output must be byte-identical to the old CLI
# pipeline (same libav* generation, same options). Needs homebrew ffmpeg
# (reference encoder + input synthesis) and clang.
# Usage: Scripts/golden-test.sh [bitrate_kbps]  (default 640)
set -eu
cd "$(dirname "$0")/.."
KBPS="${1:-640}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# 6 channels, distinct tone each (channel-order bugs can't hide).
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=3.2" \
  -f lavfi -i "sine=frequency=550:duration=3.2" \
  -f lavfi -i "sine=frequency=660:duration=3.2" \
  -f lavfi -i "sine=frequency=770:duration=3.2" \
  -f lavfi -i "sine=frequency=880:duration=3.2" \
  -f lavfi -i "sine=frequency=990:duration=3.2" \
  -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]amerge=inputs=6,pan=5.1|FL=c0|FR=c1|FC=c2|LFE=c3|BL=c4|BR=c5[a]" \
  -map "[a]" -c:a pcm_s16le -f s16le "$T/raw.pcm"
# Trim to a whole number of 1536-frame input units (18432 bytes each).
UNITS="$(($(stat -f%z "$T/raw.pcm") / 18432))"
[ "$UNITS" -ge 1 ] || { echo "input too short"; exit 1; }
dd if="$T/raw.pcm" of="$T/in.pcm" bs=18432 "count=$UNITS" 2>/dev/null

# Reference: the exact CLI pipeline the app used to run.
ffmpeg -hide_banner -loglevel error \
  -f s16le -ar 48000 -ac 6 -i "$T/in.pcm" \
  -c:a ac3 -b:a "${KBPS}k" -ar 48000 -flush_packets 1 -f spdif "$T/ref.spdif"

clang Scripts/golden-main.c Sources/CZeroB77/zb77.c \
  -IThirdParty/include -ISources/CZeroB77/include \
  ThirdParty/lib/libavformat.a ThirdParty/lib/libavcodec.a ThirdParty/lib/libavutil.a \
  -o "$T/test_static"
"$T/test_static" "$T/in.pcm" "$T/dut.spdif" "$KBPS"
cmp "$T/ref.spdif" "$T/dut.spdif" && echo "GOLDEN-IDENTICAL ($UNITS units, ${KBPS} kbps)"
