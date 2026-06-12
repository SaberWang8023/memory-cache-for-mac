#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.ramdisk"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_SCRIPT="$HOME/.local/bin/create_ram_disk.sh"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true

rm -f "$PLIST_PATH" "$INSTALL_SCRIPT"

echo "Uninstalled $LABEL"
echo "Ramdisk volumes are not unmounted automatically."
