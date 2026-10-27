#!/bin/zsh
# Measures launch-to-window time of a release build against an empty SwiftUI app (Command Line Tools only).
# Opens and closes windows: don't type while it runs. Usage: scripts/LaunchBench/run.sh [runs]
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
RUNS=${1:-7}
BUDGET=230   # ms over the empty app; measured ~155–175 in v0.9.21 (M4 Max)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
swift build -c release --sdk "$SDK" 2>&1 | grep -E "error:|warning:" || true
swiftc -O -sdk "$SDK" "$ROOT/scripts/LaunchBench/timer.swift" -o "$WORK/timer"
swiftc -O -parse-as-library -sdk "$SDK" "$ROOT/scripts/LaunchBench/baseline.swift" -o "$WORK/baseline"
caffeinate -u -t 120 &
CAF=$!
BASE=($("$WORK/timer" "$WORK/baseline" $RUNS /tmp))
APP=($("$WORK/timer" "$ROOT/.build/release/QCpie" $RUNS "$ROOT"))
kill $CAF 2>/dev/null || true
OVER=$(( APP[1] - BASE[1] ))
echo "Empty SwiftUI app: ${BASE[1]} ms warm (runs: ${BASE[2,-1]})"
echo "QCpie:             ${APP[1]} ms warm (runs: ${APP[2,-1]}), first run is cold"
echo "QCpie over empty:  ${OVER} ms (budget ${BUDGET} ms)"
if (( OVER <= BUDGET )); then echo "ALL PASSED"; else echo "FAILED: launch is ${OVER} ms over the empty app"; exit 1; fi
