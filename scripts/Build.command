#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=========================================="
echo " Building QCpie..."
echo "=========================================="

"${SCRIPT_DIR}/BuildApp.sh"

echo ""
echo "=========================================="
echo " Build finished successfully!"
echo " QCpie.app is located at: build/QCpie.app"
echo "=========================================="
open build/
