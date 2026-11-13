#!/bin/zsh
# Builds, in dist/:
#   LineFinder-<panel version>.pkg            the exporter into MediaCore/LineFinder (made the logged-in user's, so the
#                                             panel can update it later without a password) and the UXP panel
#                                             (LineFinder.ccx, installed for that user with Adobe's agent)
#   LineFinder-<panel version>.dmg            the .pkg plus a Privacy & Security link, for first installs
#   LineFinder-<panel version>.ccx            the panel alone, for the panel's own updates
#   LineFinderAnalysis-<exporter version>.zip the exporter alone (stored, no compression: the panel unzips it)
# Every QCpie release attaches all four. Bump exporter/VERSION when the exporter changes.
#
# Unsigned by default: Gatekeeper then blocks the .pkg on other Macs (right-click → Open, or System Settings →
# Privacy & Security → Open Anyway). For distribution set:
#   DEVELOPER_ID_APP="Developer ID Application: Name (TEAMID)"        signs the exporter (hardened runtime)
#   DEVELOPER_ID_INSTALLER="Developer ID Installer: Name (TEAMID)"    signs the .pkg
#   NOTARY_PROFILE=<notarytool keychain profile>                      notarizes and staples the .pkg
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREMIERE="$(dirname "$HERE")"
VERSION="$(python3 -c "import json; print(json.load(open('$PREMIERE/panel/manifest.json'))['version'])")"
WORK="$HERE/build"
DIST="$HERE/dist"
EXPORTER_VERSION="$(tr -d '[:space:]' < "$PREMIERE/exporter/VERSION")"
PKG="$DIST/LineFinder-$VERSION.pkg"
rm -rf "$WORK" && mkdir -p "$WORK/root" "$DIST"

# Exporter
# REUSE_EXPORTER=1: package the existing exporter/build bundle (no Premiere SDK on this Mac, exporter unchanged).
[[ -n "${REUSE_EXPORTER:-}" ]] || "$PREMIERE/exporter/build.sh"
MEDIACORE="$WORK/root/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/LineFinder"
mkdir -p "$MEDIACORE"
cp -R "$PREMIERE/exporter/build/LineFinderAnalysis.bundle" "$MEDIACORE/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $EXPORTER_VERSION" -c "Set :CFBundleVersion $EXPORTER_VERSION" \
  "$MEDIACORE/LineFinderAnalysis.bundle/Contents/Info.plist"
if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$MEDIACORE/LineFinderAnalysis.bundle"
else
  codesign --force --sign - "$MEDIACORE/LineFinderAnalysis.bundle"
fi

# Panel (.ccx = zip with manifest.json at the root) and the uninstaller
SUPPORT="$WORK/root/Library/Application Support/LineFinder"
mkdir -p "$SUPPORT"
(cd "$PREMIERE/panel" && zip -qrX "$SUPPORT/LineFinder.ccx" manifest.json index.html index.js presets -x "*.DS_Store")
cp "$SUPPORT/LineFinder.ccx" "$DIST/LineFinder-$VERSION.ccx"
rm -f "$DIST/LineFinderAnalysis-$EXPORTER_VERSION.zip"
(cd "$MEDIACORE" && COPYFILE_DISABLE=1 zip -qr0X "$DIST/LineFinderAnalysis-$EXPORTER_VERSION.zip" LineFinderAnalysis.bundle -x "*.DS_Store")
cp "$HERE/uninstall.sh" "$SUPPORT/uninstall.sh"
chmod 755 "$SUPPORT/uninstall.sh"

# Package. A relocatable bundle would be installed over any other copy with the same bundle id instead of into
# MediaCore. (The payload lists ._ entries for com.apple.provenance, which macOS won't let us strip; Installer
# restores them as attributes, not files.)
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
python3 - "$WORK/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
components = plistlib.load(open(path, "rb"))
for c in components:
    c["BundleIsRelocatable"] = False
    c["BundleIsVersionChecked"] = False  # reinstalling an older build must still replace the exporter
plistlib.dump(components, open(path, "wb"))
PY
COPYFILE_DISABLE=1 pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --scripts "$HERE/scripts" \
  --identifier com.qcpie.linefinder --version "$VERSION" --install-location / "$WORK/LineFinder-component.pkg"
SIGN=()
[[ -n "${DEVELOPER_ID_INSTALLER:-}" ]] && SIGN=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp)
# Fewest Installer pages (updates come from the panel's Update button): no destination or customise pages, so it is
# Continue → Install → password → Close.
productbuild --synthesize --package "$WORK/LineFinder-component.pkg" "$WORK/distribution.xml" >/dev/null
python3 - "$WORK/distribution.xml" "$VERSION" <<'PY2'
import re, sys
path, version = sys.argv[1], sys.argv[2]
xml = open(path).read()
pages = (f'<title>LineFinder {version}</title>\n'
         '    <options customize="never" require-scripts="false" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>\n'
         '    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>')
xml, n = re.subn(r'<options [^>]*/>', pages, xml, count=1)
assert n == 1, "productbuild --synthesize changed its output"
open(path, "w").write(xml)
PY2
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" "${SIGN[@]}" "$PKG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
# First installs: the .pkg in a DMG with a link to Privacy & Security (macOS blocks the unsigned .pkg until Open Anyway).
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp "$PKG" "$STAGE/"
"$PREMIERE/../scripts/privacy-link.sh" "$STAGE" "the installer"
rm -f "$DIST/LineFinder-$VERSION.dmg"
hdiutil create -quiet -volname "LineFinder $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/LineFinder-$VERSION.dmg"
echo "Built $PKG, LineFinder-$VERSION.dmg, LineFinder-$VERSION.ccx, LineFinderAnalysis-$EXPORTER_VERSION.zip"
