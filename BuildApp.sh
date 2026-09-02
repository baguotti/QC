#!/bin/bash
set -e

echo "🔨 Building THE LINEFINDER 5000 for Apple Silicon (Release mode)..."

BIN_NAME="LineFinder5000"
APP_NAME="THE LINEFINDER 5000"
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
cp "${BIN_DIR}/${BIN_NAME}" "${MACOS}/${BIN_NAME}"

# 4. Create Info.plist
cat << EOF > "${CONTENTS}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.studio.linefinder5000</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>5.0.0</string>
    <key>CFBundleVersion</key>
    <string>5000</string>
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
echo "📦 You can now double-click or drag '${APP_NAME}.app' to /Applications or any Silicon Mac!"
