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

# Version & Git Metadata
APP_VERSION="0.1.0"
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "63ffe20")
GIT_COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "1")
REPO_URL="https://github.com/baguotti/QC"

echo "📌 Version: v${APP_VERSION} (Commit: ${GIT_COMMIT}, Build: ${GIT_COMMIT_COUNT})"

# 1. Generate/update AppVersion.swift with current commit
cat << EOF > "Sources/VideoQCApp/AppVersion.swift"
import Foundation

/// Application Version and Git Repository Metadata
public struct AppVersionInfo {
    public static let version = "${APP_VERSION}"
    public static let gitCommit = "${GIT_COMMIT}"
    public static let repoURLString = "${REPO_URL}"
    
    public static var commitURL: URL {
        URL(string: "\(repoURLString)/commit/\(gitCommit)") ?? URL(string: repoURLString)!
    }
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
    <string>com.studio.linefinder5000</string>
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
    <key>GitCommitHash</key>
    <string>${GIT_COMMIT}</string>
    <key>GitRepoURL</key>
    <string>${REPO_URL}</string>
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
