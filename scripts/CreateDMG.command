#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=========================================="
echo " 💿 Building QCpie Standalone DMG"
echo "=========================================="
echo ""

"${SCRIPT_DIR}/CreateDMG.sh"

echo ""
echo "=========================================="
echo " ✅ DMG built successfully!"
echo " Opening build directory in Finder..."
echo "=========================================="
open build/

echo ""
read -p "Press [Enter] to exit..."
