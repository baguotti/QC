#!/bin/bash
# Release in two steps, so the build is opened on the oldest supported macOS before anyone gets it:
#   scripts/Release.sh build              tests, release app, build/QCpie.dmg
#   scripts/Release.sh publish "notes"    pushes main, tags vX.Y.Z, publishes the DMG as the latest GitHub release
#                                         (add --yes to skip the macOS 15 question: it was checked already)
# The version is APP_VERSION in BuildApp.sh; bump and commit it first.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION=$(sed -n 's/^APP_VERSION="\(.*\)"/\1/p' scripts/BuildApp.sh)
TAG="v${VERSION}"
DMG="build/QCpie.dmg"
STAMP="build/.release-built"
[ -n "$VERSION" ] || { echo "No APP_VERSION in scripts/BuildApp.sh"; exit 1; }

clean() { [ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Commit or stash tracked changes first."; exit 1; }; }
untagged() { ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || { echo "${TAG} already exists: bump APP_VERSION."; exit 1; }; }

case "${1:-}" in
build)
    clean; untagged
    swift test
    scripts/build_ffprobe.sh   # once per machine (skips when built): Inspect reads specs of files macOS can't open
    scripts/BuildApp.sh
    [ -x build/QCpie.app/Contents/Resources/Helpers/ffprobe ] || { echo "ffprobe missing from the app."; exit 1; }
    clean   # BuildApp.sh rewrites AppVersion.swift: it must already hold this version
    STAGE=$(mktemp -d)
    cp -R build/QCpie.app "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    scripts/privacy-link.sh "$STAGE" QCpie
    rm -f "$DMG"
    hdiutil create -quiet -volname QCpie -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    git rev-parse HEAD > "$STAMP"
    echo "✅ ${DMG} (${VERSION}). Open it on the oldest supported macOS (15), check it launches, then:"
    echo "   scripts/Release.sh publish \"what changed\""
    ;;
publish)
    NOTES="${2:?Usage: scripts/Release.sh publish \"release notes\"}"
    clean; untagged
    # Every release carries the current Premiere plugin installer: its Update button reads the latest release.
    # QCpie.dmg must stay the only .dmg: QCpie 0.15.15 and older update from the first .dmg listed (alphabetical).
    PLUGIN_VERSION="$(python3 -c "import json; print(json.load(open('premiere/panel/manifest.json'))['version'])")"
    EXPORTER_VERSION="$(tr -d '[:space:]' < premiere/exporter/VERSION)"
    PKG="premiere/package/dist/LineFinder-${PLUGIN_VERSION}.pkg"
    CCX="premiere/package/dist/LineFinder-${PLUGIN_VERSION}.ccx"
    PLUGIN_INSTALLER="premiere/package/dist/LineFinder-Installer-${PLUGIN_VERSION}.zip"
    EXPORTER_ZIP="premiere/package/dist/LineFinderAnalysis-${EXPORTER_VERSION}.zip"
    for f in "$PKG" "$PLUGIN_INSTALLER" "$CCX" "$EXPORTER_ZIP"; do
        [ -f "$f" ] || { echo "Missing ${f}: run premiere/package/build_mac.sh first."; exit 1; }
    done
    [ -f "$DMG" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$(git rev-parse HEAD)" ] || { echo "Run 'scripts/Release.sh build' on this commit first."; exit 1; }
    if [ "${3:-}" != "--yes" ]; then
        read -r -p "Did ${VERSION} launch on the macOS 15 Mac? [y/N] " answer
        [ "$answer" = "y" ] || { echo "Not published."; exit 1; }
    fi
    git push origin main
    git tag "$TAG"
    git push origin "$TAG"
    gh release create "$TAG" "$DMG" "$PLUGIN_INSTALLER" "$PKG" "$CCX" "$EXPORTER_ZIP" --latest --title "QCpie ${VERSION}" --notes "$NOTES"
    ;;
*)
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
