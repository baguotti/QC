#!/bin/bash
# Burned-in subtitle reading against a reference .srt. Must print ALL PASSED after any change to
# Sources/VideoQCLib/BurnedSubtitleReader.swift.
#   scripts/SubtitleOCRBench/run.sh [clip reference.srt [samples/s] [language|auto] [out.srt]]
# Without arguments: the LNEH test clip on RIC_2TB.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$DIR/../.."
BIN="${TMPDIR:-/tmp}/SubtitleOCRBench"
BUILD="$(mktemp -d)"
cp "$DIR/main.swift" "$BUILD/main.swift"
swiftc -O -o "$BIN" "$BUILD/main.swift" "$DIR/shim.swift" \
    "$ROOT/Sources/VideoQCLib/BurnedSubtitleReader.swift" "$ROOT/Sources/VideoQCLib/SubtitleParser.swift"
rm -rf "$BUILD"
if [ $# -eq 0 ]; then
    set -- "/Volumes/RIC_2TB/LNEH_ROUGHCUT_24fps_E6.2_SUBS_TEST.mp4" "/Volumes/RIC_2TB/LNEH_ROUGHCUT_24fps_E6.2_SUBS_TEST.srt"
fi
"$BIN" "$@"
