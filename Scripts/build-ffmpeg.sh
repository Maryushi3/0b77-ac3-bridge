#!/bin/sh
# Reproducible minimal ffmpeg static build: libavcodec + libavformat (spdif
# muxer) + libavutil, with ONLY the native AC-3 encoder + spdif muxer enabled.
# No external libs, no GPL components -> LGPL 2.1.
# Keep this script + the pinned version as the compliance story (see MAINTAINING).
# Output: ThirdParty/lib/*.a, ThirdParty/include/**  (~10 MB, committed).
# Usage: Scripts/build-ffmpeg.sh   (needs: clang, make, curl — CLT is enough)
set -eu
cd "$(dirname "$0")/.."

VER="9.0.2"
TARBALL="ffmpeg-$VER.tar.xz"
URL="https://ffmpeg.org/releases/$TARBALL"
ROOT="$PWD"
WORK="$ROOT/tmp/ffmpeg-src"
OUT="$ROOT/ThirdParty"

command -v clang >/dev/null || { echo "needs Xcode CLT (clang)"; exit 1; }
# Match the app's deployment target so the .a files link cleanly for macOS 14+.
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$WORK" "$OUT"
cd "$WORK"
[ -f "$TARBALL" ] || curl -sL -o "$TARBALL" "$URL"
rm -rf "ffmpeg-$VER"
tar xf "$TARBALL"
cd "ffmpeg-$VER"
./configure \
  --disable-everything --disable-programs --disable-doc \
  --disable-avdevice --disable-avfilter \
  --disable-swscale --disable-swresample --disable-network --disable-autodetect \
  --enable-encoder=ac3 --enable-muxer=spdif \
  --enable-static --disable-shared \
  --arch=arm64 --target-os=darwin --cc=clang \
  --prefix="$WORK/out" >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
rm -rf "$OUT/lib" "$OUT/include"
mkdir -p "$OUT/lib"
cp libavcodec/libavcodec.a libavformat/libavformat.a libavutil/libavutil.a "$OUT/lib/"
cp -R "$WORK/out/include" "$OUT/include"
echo "ThirdParty libs ready:"
ls -la "$OUT/lib/"
