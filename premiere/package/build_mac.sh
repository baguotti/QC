#!/bin/zsh
# Builds dist/LineFinder-<version>.pkg: the exporter into Premiere's MediaCore plug-ins folder and the UXP panel
# (LineFinder.ccx, installed for the logged-in user with Adobe's Unified Plugin Installer Agent).
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
PKG="$DIST/LineFinder-$VERSION.pkg"
rm -rf "$WORK" && mkdir -p "$WORK/root" "$DIST"

# Exporter
"$PREMIERE/exporter/build.sh"
MEDIACORE="$WORK/root/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"
mkdir -p "$MEDIACORE"
cp -R "$PREMIERE/exporter/build/LineFinderAnalysis.bundle" "$MEDIACORE/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" \
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
productbuild --package "$WORK/LineFinder-component.pkg" "${SIGN[@]}" "$PKG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
echo "Built $PKG"
