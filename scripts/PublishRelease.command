#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=========================================="
echo " 🌐 QCpie - Publish GitHub Release"
echo "=========================================="
echo ""

CURRENT_VER=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' Sources/VideoQCApp/AppVersion.swift 2>/dev/null || echo "0.4.7")
DEFAULT_TAG="v${CURRENT_VER}"

read -p "Enter release tag/version [default: ${DEFAULT_TAG}]: " INPUT_TAG
TAG_NAME="${INPUT_TAG:-$DEFAULT_TAG}"

if [[ ! "$TAG_NAME" =~ ^v ]]; then
    TAG_NAME="v${TAG_NAME}"
fi

echo "📌 Target Release Tag: ${TAG_NAME}"
echo ""

echo "🔨 Building DMG installer package..."
"${SCRIPT_DIR}/CreateDMG.sh"
DMG_FILE="build/QCpie.dmg"

if [ ! -f "$DMG_FILE" ]; then
    echo "❌ Error: DMG not found at $DMG_FILE"
    exit 1
fi

echo ""
echo "🏷️ Creating and pushing git tag '${TAG_NAME}'..."
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    echo "⚠️  Tag ${TAG_NAME} already exists locally. Forcing update..."
    git tag -f -a "$TAG_NAME" -m "QCpie Release ${TAG_NAME}"
else
    git tag -a "$TAG_NAME" -m "QCpie Release ${TAG_NAME}"
fi

git push origin "$TAG_NAME" --force
echo "✅ Pushed tag ${TAG_NAME} to GitHub."
echo ""

if command -v gh >/dev/null 2>&1; then
    echo "🚀 GitHub CLI (gh) detected. Publishing release automatically..."
    gh release create "$TAG_NAME" "$DMG_FILE" \
        --title "QCpie ${TAG_NAME}" \
        --generate-notes \
        || gh release upload "$TAG_NAME" "$DMG_FILE" --clobber
    
    echo "✅ Release ${TAG_NAME} published successfully on GitHub!"
else
    echo "ℹ️  GitHub CLI (gh) not found."
    echo "🌐 Opening GitHub new release page in your browser..."
    echo "📂 Revealing QCpie.dmg in Finder..."
    
    RELEASE_URL="https://github.com/baguotti/QC/releases/new?tag=${TAG_NAME}&title=QCpie+${TAG_NAME}"
    open "$RELEASE_URL"
    open -R "$DMG_FILE"
    
    echo ""
    echo "👉 Drag & drop QCpie.dmg into the GitHub Release page 'Attach binaries' box, then click 'Publish release'!"
fi

echo ""
echo "=========================================="
echo " 🎉 Release process complete!"
echo "=========================================="
read -p "Press [Enter] to exit..."
