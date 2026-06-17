#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.memory-cache"
OLD_LABEL="com.local.ramdisk"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_SCRIPT="$HOME/.local/bin/create_memory_cache.sh"
CONFIG_PATH="$HOME/.config/memory-cache-for-mac/config"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
OLD_INSTALL_SCRIPT="$HOME/.local/bin/create_ram_disk.sh"
SKIP_LAUNCHCTL="${MEMORY_CACHE_SKIP_LAUNCHCTL:-0}"

bootout_if_needed() {
  label=$1
  plist=$2
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
}

bootout_if_needed "$LABEL" "$PLIST_PATH"
bootout_if_needed "$OLD_LABEL" "$OLD_PLIST_PATH"

rm -f "$PLIST_PATH" "$INSTALL_SCRIPT" "$CONFIG_PATH"
rm -f "$OLD_PLIST_PATH" "$OLD_INSTALL_SCRIPT"

echo "Uninstalled $LABEL"
echo "Manual cleanup, if desired:"
echo "  umount ~/tmpfs"
echo "  diskutil eject /Volumes/Ramdisk"
echo "Mount roots are not unmounted or deleted automatically."
