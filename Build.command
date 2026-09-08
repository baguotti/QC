#!/usr/bin/env bash
set -e

# Navigate to the directory where this script is located
cd "$(dirname "$0")"

echo "=========================================="
echo " Building QCpie..."
echo "=========================================="

./BuildApp.sh

echo ""
echo "=========================================="
echo " Build finished successfully!"
echo " QCpie.app is located at: build/QCpie.app"
echo "=========================================="
open build/
