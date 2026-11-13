#!/bin/bash
# Writes a Finder link that opens System Settings → Privacy & Security, for the first-install DMGs (QCpie, LineFinder):
# macOS blocks the unsigned app or installer before any of its code runs, and Open Anyway is on that page.
# A link is a document, not code, so it opens even while the app is blocked.
# Usage: scripts/privacy-link.sh <folder> "<app name>"
set -euo pipefail
FILE="$1/If macOS blocks $2, open this.inetloc"
cat > "$FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>URL</key><string>x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension</string>
</dict></plist>
PLIST
plutil -lint -s "$FILE"
