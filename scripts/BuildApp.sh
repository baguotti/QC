#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "🔨 Building QCpie for Apple Silicon (Release mode)..."

BIN_NAME="QCpie"
APP_NAME="QCpie"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

# Version & Metadata
APP_VERSION="0.7.0"
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
SWIFT_BUILD_FLAGS=()
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ] && ! [ -f "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
    SWIFT_BUILD_FLAGS+=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi

swift build -c release "${SWIFT_BUILD_FLAGS[@]}"
BIN_DIR=$(swift build -c release "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)

# 3. Setup bundle structure
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}" "${RESOURCES}"

# 4. Copy executable & resources
cp "${BIN_DIR}/${BIN_NAME}" "${MACOS}/${BIN_NAME}"

if [ -f "Resources/AppIcon.icns" ]; then
    echo "🎨 Bundling application icon (AppIcon.icns)..."
    cp "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

if [ -d "Resources/PlayAnimation" ]; then
    echo "🎞️ Bundling PlayAnimation frames..."
    mkdir -p "${RESOURCES}/PlayAnimation"
    cp Resources/PlayAnimation/*.png "${RESOURCES}/PlayAnimation/"
fi

if [ -f "Resources/TikTokSafeAreaTemplateBlack.png" ]; then
    echo "📱 Bundling TikTok safe area overlay..."
    cp "Resources/TikTokSafeAreaTemplateBlack.png" "${RESOURCES}/TikTokSafeAreaTemplateBlack.png"
fi

if [ -f "Resources/Click.aac" ]; then
    echo "🔊 Bundling Click.aac..."
    cp "Resources/Click.aac" "${RESOURCES}/Click.aac"
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
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video Media</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.video</string>
                <string>public.audiovisual-content</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.mpeg-4</string>
                <string>com.apple.m4v-video</string>
                <string>public.avi</string>
                <string>org.matroska.mkv</string>
                <string>org.webmproject.webm</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mp4</string>
                <string>mov</string>
                <string>m4v</string>
                <string>mkv</string>
                <string>avi</string>
                <string>prores</string>
                <string>webm</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
                <string>public.directory</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.matroska.mkv</string>
            <key>UTTypeDescription</key>
            <string>Matroska Video</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.movie</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mkv</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.apple.prores-video</string>
            <key>UTTypeDescription</key>
            <string>Apple ProRes Video</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.movie</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>prores</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# 6. Create PkgInfo
echo -n "APPL????" > "${CONTENTS}/PkgInfo"

# 7. Ad-Hoc Code Signing
echo "🔐 Ad-hoc code signing app bundle..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "✅ Successfully built: ${APP_BUNDLE}"
if [ -d "/Applications/${APP_NAME}.app" ]; then
    echo "📲 Updating /Applications/${APP_NAME}.app..."
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_NAME}.app"
    echo "✅ /Applications/${APP_NAME}.app updated successfully!"
fi
echo "📦 You can now double-click or drag '${APP_NAME}.app' to /Applications or any Silicon Mac!"
