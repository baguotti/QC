#!/bin/zsh
# Removes LineFinder: the exporter (needs admin) and the UXP panel for the current user.
# Usage: sudo "/Library/Application Support/LineFinder/uninstall.sh"
UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
if [[ -x "$UPIA" ]]; then
  launchctl asuser "$(id -u "$USER_NAME")" sudo -u "$USER_NAME" "$UPIA" --remove LineFinder
fi
rm -rf "/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/LineFinderAnalysis.bundle"
rm -rf "/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/LineFinder"
rm -rf "/Library/Application Support/LineFinder"
pkgutil --forget com.qcpie.linefinder >/dev/null 2>&1
echo "LineFinder removed. Restart Premiere Pro."
