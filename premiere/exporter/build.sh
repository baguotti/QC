#!/bin/bash
# Builds LineFinderAnalysis.bundle (arm64 + x86_64). PREMIERE_SDK = the Premiere Pro C++ SDK folder.
# ./build.sh install also copies it into Premiere's MediaCore plug-ins folder (sudo only if the folder isn't writable).
set -euo pipefail
cd "$(dirname "$0")"
SDK="${PREMIERE_SDK:-$HOME/Downloads/Premiere Pro 27.0 C++ SDK}"
OUT=build/LineFinderAnalysis.bundle
rm -rf "$OUT" && mkdir -p "$OUT/Contents/MacOS"
# linecore needs FP contraction off to match QCpie's Swift detector bit for bit.
clang++ -std=c++17 -O2 -ffp-contract=off -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -Wall -Wno-four-char-constants -Wno-multichar -Wno-unused-variable \
  -isystem "$SDK/Examples/Headers" -I ../linecore/include \
  LineFinderExporter.cpp ../linecore/src/linecore.cpp -o "$OUT/Contents/MacOS/LineFinderAnalysis"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LineFinderAnalysis</string>
  <key>CFBundleIdentifier</key><string>com.qcpie.linefinder.exporter</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
</dict></plist>
PLIST
codesign --force --sign - "$OUT"
echo "Built $OUT"
if [[ "${1:-}" == install ]]; then
  DEST="/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"
  SUDO=; [[ -w "$DEST" ]] || SUDO=sudo
  $SUDO rm -rf "$DEST/LineFinderAnalysis.bundle"
  $SUDO cp -R "$OUT" "$DEST/"
  echo "Installed to $DEST (restart Premiere Pro)"
fi
