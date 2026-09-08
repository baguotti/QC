#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=========================================="
echo " 🚀 QCpie - Complete Build & GitHub Release"
echo "=========================================="
echo ""

# 1. Detect / Configure Version
CURRENT_VER=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' Sources/VideoQCApp/AppVersion.swift 2>/dev/null || echo "0.4.7")
read -p "Enter version number [current: ${CURRENT_VER}]: " INPUT_VER
RELEASE_VER="${INPUT_VER:-$CURRENT_VER}"

# Ensure clean semantic version without leading 'v' for files
RELEASE_VER="${RELEASE_VER#v}"
TAG_NAME="v${RELEASE_VER}"

echo "📌 Version: ${RELEASE_VER} (Tag: ${TAG_NAME})"

# Update AppVersion.swift
cat << EOF > "Sources/VideoQCApp/AppVersion.swift"
import Foundation

/// Application Version Metadata
public struct AppVersionInfo {
    public static let version = "${RELEASE_VER}"
}
EOF

# Update APP_VERSION in scripts/BuildApp.sh
sed -i '' -E "s/APP_VERSION=\"[^\"]+\"/APP_VERSION=\"${RELEASE_VER}\"/" scripts/BuildApp.sh 2>/dev/null || true

echo ""
echo "=========================================="
echo " 🔨 1/4 Building App Bundle & Standalone DMG..."
echo "=========================================="
"${SCRIPT_DIR}/CreateDMG.sh"

DMG_FILE="build/QCpie.dmg"
if [ ! -f "$DMG_FILE" ]; then
    echo "❌ Error: DMG not found at $DMG_FILE"
    exit 1
fi

echo ""
echo "=========================================="
echo " 💾 2/4 Git Commit & Push..."
echo "=========================================="
git status -s
echo ""

read -p "Enter commit message [default: Release ${TAG_NAME}]: " INPUT_MSG
COMMIT_MSG="${INPUT_MSG:-Release ${TAG_NAME}}"

git add -A

if [ -n "$(git status --porcelain)" ]; then
    git commit -m "$COMMIT_MSG"
    echo "✅ Changes committed: '$COMMIT_MSG'"
else
    echo "ℹ️ No unstaged changes to commit."
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "🚀 Pushing branch to origin/${BRANCH}..."
git push origin "$BRANCH"

echo ""
echo "=========================================="
echo " 🏷️ 3/4 Tagging & Releasing ${TAG_NAME}..."
echo "=========================================="
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    echo "⚠️  Tag ${TAG_NAME} exists locally. Forcing update..."
    git tag -f -a "$TAG_NAME" -m "QCpie Release ${TAG_NAME}"
else
    git tag -a "$TAG_NAME" -m "QCpie Release ${TAG_NAME}"
fi

git push origin "$TAG_NAME" --force
echo "✅ Pushed tag ${TAG_NAME} to GitHub."

echo ""
echo "=========================================="
echo " 🌐 4/4 Publishing Release to GitHub..."
echo "=========================================="
if command -v gh >/dev/null 2>&1; then
    echo "🚀 GitHub CLI (gh) detected. Publishing release asset directly..."
    gh release create "$TAG_NAME" "$DMG_FILE" \
        --title "QCpie ${TAG_NAME}" \
        --generate-notes \
        || gh release upload "$TAG_NAME" "$DMG_FILE" --clobber
    
    echo "✅ Release ${TAG_NAME} with QCpie.dmg published to GitHub!"
else
    echo "ℹ️  GitHub CLI (gh) not found."
    echo "🌐 Opening GitHub new release page in your browser..."
    echo "📂 Revealing QCpie.dmg in Finder..."
    
    RELEASE_URL="https://github.com/baguotti/QC/releases/new?tag=${TAG_NAME}&title=QCpie+${TAG_NAME}"
    open "$RELEASE_URL"
    open -R "$DMG_FILE"
    
    echo ""
    echo "👉 Drag & drop QCpie.dmg into GitHub's 'Attach binaries' box, then click 'Publish release'!"
fi

echo ""
echo "=========================================="
echo " 🎉 Full Pipeline Completed Successfully!"
echo "=========================================="
read -p "Press [Enter] to exit..."
