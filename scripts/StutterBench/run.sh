#!/bin/zsh
# Builds and runs the Stutter Finder benchmark with the Command Line Tools.
# Usage: scripts/StutterBench/run.sh [--no-real]
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT"/Sources/VideoQCLib/*.swift "$ROOT"/scripts/StutterBench/main.swift "$WORK"/
swiftc -O -sdk "$SDK" -module-name StutterBench "$WORK"/*.swift -o "$WORK/bench"
cd "$ROOT" && "$WORK/bench" "$@"
