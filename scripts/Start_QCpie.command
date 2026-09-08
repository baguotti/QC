#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

APP_PATH="${PROJECT_ROOT}/build/QCpie.app"

if [ ! -d "$APP_PATH" ]; then
    echo "QCpie.app not found. Building first..."
    "${SCRIPT_DIR}/BuildApp.sh"
fi

echo "Launching QCpie..."
open "$APP_PATH"
