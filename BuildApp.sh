#!/bin/bash
set -e

echo "🔨 Building QCpie for Apple Silicon (Release mode)..."

BIN_NAME="QCpie"
APP_NAME="QCpie"
BUILD_DIR="$(pwd)/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

# Version & Metadata
APP_VERSION="0.2.6"
GIT_COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "1")

echo "📌 Version: v${APP_VERSION} (Build: ${GIT_COMMIT_COUNT})"

# 1. Generate/update AppVersion.swift
cat << EOF > "Sources/VideoQCApp/AppVersion.swift"
import Foundation

/// Application Version Metadata
public struct AppVersionInfo {
    public static let version = "${APP_VERSION}"
}
EOF

# 2. Compile release binary
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

# 3. Setup bundle structure
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}"

# 4. Copy executable & resources
cp "${BIN_DIR}/${BIN_NAME}" "${MACOS}/${BIN_NAME}"

if [ -f "Resources/AppIcon.icns" ]; then
    echo "🎨 Bundling application icon (AppIcon.icns)..."
    cp "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

# 5. Create Info.plist
cat << EOF > "${CONTENTS}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.studio.qcpie</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${GIT_COMMIT_COUNT}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# 5. Create PkgInfo
echo -n "APPL????" > "${CONTENTS}/PkgInfo"

# 6. Ad-Hoc Code Signing
echo "🔐 Ad-hoc code signing app bundle..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "✅ Successfully built: ${APP_BUNDLE}"
echo "📦 You can now double-click or drag '${APP_NAME}.app' to /Applications or any Silicon Mac!"
