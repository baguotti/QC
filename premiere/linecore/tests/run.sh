#!/bin/zsh
# linecore parity with QCpie's Swift detector (Command Line Tools only).
# Usage: premiere/linecore/tests/run.sh [footage folder, default _TEST] [--no-real] [--all (include files ≥ 500 MB)] [--segments (print them)]
set -e
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LC="$ROOT/premiere/linecore"
SDK="$(xcrun --show-sdk-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
clang++ -std=c++17 -O2 -ffp-contract=off -Wall -Wextra -I "$LC/include" -c "$LC/src/linecore.cpp" -o "$WORK/linecore.o"
cp "$ROOT"/Sources/VideoQCLib/*.swift "$ROOT"/Tests/LineFinderScenes.swift "$LC/tests/parity.swift" "$WORK"/
mv "$WORK/parity.swift" "$WORK/main.swift"
sed -i '' -e '/^@testable import VideoQCLib$/d' -e '/^import VideoQCLib$/d' -e '/^typealias RGBColor = VideoQCLib.RGBColor$/d' "$WORK"/*.swift
swiftc -O -sdk "$SDK" -module-name Parity -import-objc-header "$LC/include/linecore.h" "$WORK"/*.swift "$WORK/linecore.o" -lc++ -o "$WORK/parity"
cd "$ROOT" && "$WORK/parity" "$@"
