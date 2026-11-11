#!/bin/bash
# Check Subs & Graphics against known answers on real deliverables. Must print ALL PASSED after any change to
# Sources/VideoQCLib/PictureTextScan.swift (or the BurnedSubtitleReader helpers it uses).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
BIN="${TMPDIR:-/tmp}/PictureTextBench"
BUILD="$(mktemp -d)"
cp "$DIR/main.swift" "$BUILD/main.swift"
swiftc -O -o "$BIN" "$BUILD/main.swift" "$ROOT/scripts/SubtitleOCRBench/shim.swift" "$ROOT/Sources/VideoQCLib/PictureTextScan.swift" \
    "$ROOT/Sources/VideoQCLib/BurnedSubtitleReader.swift" "$ROOT/Sources/VideoQCLib/SubtitleParser.swift"
rm -rf "$BUILD"
"$BIN" "$ROOT"
