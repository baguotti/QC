#!/bin/zsh
# Builds and runs the loudness benchmark (Command Line Tools + ffmpeg as the BS.1770 reference).
# Usage: scripts/LoudnessBench/run.sh [--no-real]
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT"/Sources/VideoQCLib/*.swift "$ROOT"/scripts/LoudnessBench/main.swift "$WORK"/
swiftc -O -sdk "$SDK" -module-name LoudnessBench "$WORK"/*.swift -o "$WORK/bench"
cd "$ROOT" && "$WORK/bench" "$WORK" "$@"
