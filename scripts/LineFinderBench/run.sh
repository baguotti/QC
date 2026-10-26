#!/bin/zsh
# Builds and runs the Line Finder benchmark with the Command Line Tools (the swift-testing suite needs Xcode).
# Usage: scripts/LineFinderBench/run.sh [footage folder, default _TEST] [--no-real]
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT"/Sources/VideoQCLib/*.swift "$ROOT"/Tests/LegacyEdgeDetector.swift "$ROOT"/Tests/LineFinderScenes.swift "$ROOT"/scripts/LineFinderBench/main.swift "$WORK"/
# One module: drop the library imports the test files use.
sed -i '' -e '/^@testable import VideoQCLib$/d' -e '/^import VideoQCLib$/d' -e '/^typealias RGBColor = VideoQCLib.RGBColor$/d' "$WORK"/*.swift
swiftc -O -sdk "$SDK" -module-name LineFinderBench "$WORK"/*.swift -o "$WORK/bench"
cd "$ROOT" && "$WORK/bench" "$@"
