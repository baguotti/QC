#!/bin/bash
# Builds the ffprobe QCpie bundles to read specs of files macOS can't open (Inspect only: nothing is decoded for viewing).
# LGPL configuration (no --enable-gpl, no external libraries), arm64, macOS 14+ (the app's LSMinimumSystemVersion). Output: Resources/Helpers/ffprobe
# (gitignored; BuildApp.sh copies it into the app). The source is FFmpeg's own release tarball, checked against the
# SHA-256 below (cross-checked with Homebrew's formula when pinned). Corresponding source for the LGPL: that tarball
# plus these flags. Run once per machine that builds releases (~3–5 minutes).
set -euo pipefail

VERSION="9.0.2"
SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
URL="https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/Resources/Helpers"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if [ -x "${OUT}/ffprobe" ] && [ "$(cat "${OUT}/FFMPEG_VERSION" 2>/dev/null)" = "${VERSION}" ] && [ "${1:-}" != "--force" ]; then
    echo "ffprobe ${VERSION} already built (${OUT}/ffprobe). Pass --force to rebuild."
    exit 0
fi

echo "Downloading FFmpeg ${VERSION}…"
curl -fsSL --retry 3 -o "${WORK}/ffmpeg.tar.xz" "${URL}"
ACTUAL="$(shasum -a 256 "${WORK}/ffmpeg.tar.xz" | awk '{print $1}')"
if [ "${ACTUAL}" != "${SHA256}" ]; then
    echo "error: checksum mismatch for ${URL}" >&2
    echo "  expected ${SHA256}" >&2
    echo "  got      ${ACTUAL}" >&2
    exit 1
fi
tar -xf "${WORK}/ffmpeg.tar.xz" -C "${WORK}"
cd "${WORK}/ffmpeg-${VERSION}"

echo "Configuring…"
./configure \
    --cc=clang --arch=arm64 --target-os=darwin \
    --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
    --enable-static --disable-shared --disable-debug --disable-doc --enable-small \
    --disable-autodetect --disable-network \
    --disable-programs --enable-ffprobe \
    --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
    --disable-encoders --disable-muxers --disable-hwaccels --disable-devices \
    --disable-protocols --enable-protocol=file \
    > "${WORK}/configure.log" || { tail -30 "${WORK}/configure.log" >&2; exit 1; }

echo "Building…"
make -j"$(sysctl -n hw.ncpu)" ffprobe > "${WORK}/make.log" 2>&1 || { tail -30 "${WORK}/make.log" >&2; exit 1; }
strip ffprobe

mkdir -p "${OUT}"
cp ffprobe "${OUT}/ffprobe"
cp COPYING.LGPLv2.1 "${OUT}/FFMPEG_LICENSE.txt"
echo "${VERSION}" > "${OUT}/FFMPEG_VERSION"
"${OUT}/ffprobe" -version | head -1
echo "Built ${OUT}/ffprobe ($(du -h "${OUT}/ffprobe" | awk '{print $1}'))"
