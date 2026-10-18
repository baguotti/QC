#!/bin/bash
# Builds QCpie (BuildApp.sh) and packages build/QCpie-<version>.dmg for a GitHub release.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

"$SCRIPT_DIR/BuildApp.sh"

APP_BUNDLE="build/QCpie.app"
VERSION=$(defaults read "$PROJECT_ROOT/$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)
STAGING="build/dmg"
DMG="build/QCpie-${VERSION}.dmg"

echo "💿 Packaging ${DMG}..."
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "QCpie ${VERSION}" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "✅ ${DMG} ready: attach it to the v${VERSION} GitHub release."
open -R "$DMG"
