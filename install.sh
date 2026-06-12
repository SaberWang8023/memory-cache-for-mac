#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.ramdisk"
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/src/create_ram_disk.sh"
PLIST_TEMPLATE="$SCRIPT_DIR/src/$LABEL.plist.template"
INSTALL_SCRIPT="$HOME/.local/bin/create_ram_disk.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

if [ ! -f "$SOURCE_SCRIPT" ]; then
  echo "Missing source script: $SOURCE_SCRIPT" >&2
  exit 1
fi

if [ ! -f "$PLIST_TEMPLATE" ]; then
  echo "Missing plist template: $PLIST_TEMPLATE" >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$LOG_DIR"

cp "$SOURCE_SCRIPT" "$INSTALL_SCRIPT"
chmod 755 "$INSTALL_SCRIPT"

sed "s#__HOME__#$HOME#g" "$PLIST_TEMPLATE" > "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true

if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
  echo "launchctl bootstrap failed as the current user; retrying with sudo..."
  sudo launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
fi

launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true

echo "Installed $LABEL"
echo "Script: $INSTALL_SCRIPT"
echo "LaunchAgent: $PLIST_PATH"
echo "Logs: $LOG_DIR/ramdisk.log and $LOG_DIR/ramdisk.err.log"
