#!/bin/bash
set -e

APP_NAME="THE LINEFINDER 5000"
BUILD_DIR="$(pwd)/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_STAGING="${BUILD_DIR}/dmg_staging"
DMG_OUTPUT="${BUILD_DIR}/THE_LINEFINDER_5000.dmg"

echo "💿 Creating Standalone DMG Installer for ${APP_NAME}..."

# 1. Ensure latest build exists
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "🔨 App bundle not found. Building release bundle first..."
    ./BuildApp.sh
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
