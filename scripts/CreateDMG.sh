#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="QCpie"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_STAGING="${BUILD_DIR}/dmg_staging"
DMG_OUTPUT="${BUILD_DIR}/QCpie.dmg"

echo "💿 Creating Standalone DMG Installer for ${APP_NAME}..."

# 1. Ensure latest build exists
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "🔨 App bundle not found. Building release bundle first..."
    "${SCRIPT_DIR}/BuildApp.sh"
fi

# 2. Prepare staging directory
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"

echo "📂 Staging application bundle..."
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"

echo "🔗 Creating /Applications drag-and-drop symlink..."
ln -s /Applications "${DMG_STAGING}/Applications"

# 3. Build compressed read-only DMG with hdiutil
echo "🗜️  Generating compressed Apple disk image (UDZO)..."
rm -f "${DMG_OUTPUT}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_OUTPUT}"

# 4. Clean up staging directory
rm -rf "${DMG_STAGING}"

echo "✅ DMG Creation Complete!"
echo "📦 Installer Disk Image located at:"
echo "   ${DMG_OUTPUT}"
ls -lh "${DMG_OUTPUT}"
