#!/bin/zsh
# Builds and runs the Frame Check benchmark with the Command Line Tools.
# Usage: scripts/FrameCheckBench/run.sh [--no-real]
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT"/Sources/VideoQCLib/*.swift "$ROOT"/scripts/FrameCheckBench/main.swift "$WORK"/
swiftc -O -sdk "$SDK" -module-name FrameCheckBench "$WORK"/*.swift -o "$WORK/bench"
cd "$ROOT" && "$WORK/bench" "$@"
