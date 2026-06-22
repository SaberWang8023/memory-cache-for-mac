#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.memory-cache"
OLD_LABEL="com.local.ramdisk"
SKIP_LAUNCHCTL="${MEMORY_CACHE_SKIP_LAUNCHCTL:-0}"
TARGET_HOME="${MEMORY_CACHE_TEST_TARGET_HOME:-$HOME}"
SYSTEM_ROOT="${MEMORY_CACHE_TEST_SYSTEM_ROOT:-/}"
DAEMON_PROBE_ROOT="${MEMORY_CACHE_TEST_DAEMON_PROBE_ROOT:-$SYSTEM_ROOT}"

AGENT_PLIST_PATH="$TARGET_HOME/Library/LaunchAgents/$LABEL.plist"
AGENT_INSTALL_SCRIPT="$TARGET_HOME/.local/bin/create_memory_cache.sh"
AGENT_CONFIG_PATH="$TARGET_HOME/.config/memory-cache-for-mac/config"
AGENT_LOG_FILE="$TARGET_HOME/Library/Logs/memory-cache.log"
AGENT_ERR_LOG_FILE="$TARGET_HOME/Library/Logs/memory-cache.err.log"

DAEMON_PLIST_PATH="$SYSTEM_ROOT/Library/LaunchDaemons/$LABEL.plist"
DAEMON_INSTALL_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
DAEMON_CONFIG_PATH="$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
DAEMON_LOG_FILE="$SYSTEM_ROOT/Library/Logs/memory-cache.log"
DAEMON_ERR_LOG_FILE="$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"

OLD_AGENT_PLIST_PATH="$TARGET_HOME/Library/LaunchAgents/$OLD_LABEL.plist"
OLD_AGENT_INSTALL_SCRIPT="$TARGET_HOME/.local/bin/create_ram_disk.sh"
OLD_DAEMON_PLIST_PATH="$SYSTEM_ROOT/Library/LaunchDaemons/$OLD_LABEL.plist"
OLD_DAEMON_INSTALL_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"

effective_uid() {
  if [ -n "${MEMORY_CACHE_TEST_EFFECTIVE_UID:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_EFFECTIVE_UID"
  else
    id -u
  fi
}

daemon_assets_exist() {
  [ -e "$DAEMON_PROBE_ROOT/Library/LaunchDaemons/$LABEL.plist" ] ||
  [ -e "$DAEMON_PROBE_ROOT/usr/local/libexec/create_memory_cache.sh" ] ||
  [ -e "$DAEMON_PROBE_ROOT/Library/Application Support/memory-cache-for-mac/config" ] ||
  [ -e "$DAEMON_PROBE_ROOT/Library/Logs/memory-cache.log" ] ||
  [ -e "$DAEMON_PROBE_ROOT/Library/Logs/memory-cache.err.log" ] ||
  [ -e "$DAEMON_PROBE_ROOT/Library/LaunchDaemons/$OLD_LABEL.plist" ] ||
  [ -e "$DAEMON_PROBE_ROOT/usr/local/libexec/create_ram_disk.sh" ]
}

require_daemon_uninstall_privilege() {
  if [ -n "${MEMORY_CACHE_TEST_SYSTEM_ROOT:-}" ]; then
    return
  fi

  if daemon_assets_exist && [ "$(effective_uid)" -ne 0 ]; then
    echo "Daemon uninstall requires sudo" >&2
    exit 1
  fi
}

bootout_if_needed() {
  domain=$1
  label=$2
  plist=$3
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
}

AGENT_DOMAIN="gui/$(id -u)"
DAEMON_DOMAIN="system"

require_daemon_uninstall_privilege

bootout_if_needed "$AGENT_DOMAIN" "$LABEL" "$AGENT_PLIST_PATH"
bootout_if_needed "$AGENT_DOMAIN" "$OLD_LABEL" "$OLD_AGENT_PLIST_PATH"
bootout_if_needed "$DAEMON_DOMAIN" "$LABEL" "$DAEMON_PLIST_PATH"
bootout_if_needed "$DAEMON_DOMAIN" "$OLD_LABEL" "$OLD_DAEMON_PLIST_PATH"

rm -f "$AGENT_PLIST_PATH" "$AGENT_INSTALL_SCRIPT" "$AGENT_CONFIG_PATH"
rm -f "$AGENT_LOG_FILE" "$AGENT_ERR_LOG_FILE"
rm -f "$DAEMON_PLIST_PATH" "$DAEMON_INSTALL_SCRIPT" "$DAEMON_CONFIG_PATH"
rm -f "$DAEMON_LOG_FILE" "$DAEMON_ERR_LOG_FILE"
rm -f "$OLD_AGENT_PLIST_PATH" "$OLD_AGENT_INSTALL_SCRIPT"
rm -f "$OLD_DAEMON_PLIST_PATH" "$OLD_DAEMON_INSTALL_SCRIPT"

echo "Uninstalled $LABEL"
echo "Manual cleanup, if desired:"
echo "  umount ~/tmpfs"
echo "  diskutil eject /Volumes/<APFS_DISK_NAME>"
echo "Mount roots are not unmounted or deleted automatically."
