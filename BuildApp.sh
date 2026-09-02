#!/bin/bash
set -e

echo "🔨 Building Video QC for Apple Silicon (Release mode)..."

APP_NAME="VideoQC"
BUILD_DIR="$(pwd)/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

# 1. Compile release binary
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

# 2. Setup bundle structure
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}"

# 3. Copy executable
cp "${BIN_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"

# 4. Create Info.plist
cat << 'EOF' > "${CONTENTS}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VideoQC</string>
    <key>CFBundleIdentifier</key>
    <string>com.studio.videoqc</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Video QC</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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

echo "✅ Successfully built: ${APP_BUNDLE}"
echo "📦 You can now double-click or drag ${APP_NAME}.app to /Applications or any Silicon Mac!"
