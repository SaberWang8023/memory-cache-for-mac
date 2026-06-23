#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.memory-cache"
OLD_LABEL="com.local.ramdisk"
SKIP_LAUNCHCTL="${MEMORY_CACHE_SKIP_LAUNCHCTL:-0}"
SYSTEM_ROOT="${MEMORY_CACHE_TEST_SYSTEM_ROOT:-/}"
DAEMON_PROBE_ROOT="${MEMORY_CACHE_TEST_DAEMON_PROBE_ROOT:-$SYSTEM_ROOT}"
LAUNCHCTL_BIN="${MEMORY_CACHE_TEST_LAUNCHCTL_BIN:-launchctl}"

TARGET_USER=""
TARGET_HOME=""
TARGET_UID=""

AGENT_PLIST_PATH=""
AGENT_INSTALL_SCRIPT=""
AGENT_CONFIG_PATH=""
AGENT_LOG_FILE=""
AGENT_ERR_LOG_FILE=""

DAEMON_PLIST_PATH="$SYSTEM_ROOT/Library/LaunchDaemons/$LABEL.plist"
DAEMON_INSTALL_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
DAEMON_CONFIG_PATH="$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
DAEMON_LOG_FILE="$SYSTEM_ROOT/Library/Logs/memory-cache.log"
DAEMON_ERR_LOG_FILE="$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"

OLD_AGENT_PLIST_PATH=""
OLD_AGENT_INSTALL_SCRIPT=""
OLD_DAEMON_PLIST_PATH="$SYSTEM_ROOT/Library/LaunchDaemons/$OLD_LABEL.plist"
OLD_DAEMON_INSTALL_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"

TARGET_BACKEND=""
UNINSTALL_ALL=0
UNINSTALL_APFS=0
UNINSTALL_TMPFS=0

usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [--backend tmpfs|apfs] [--all]
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --backend)
        [ "$#" -ge 2 ] || {
          echo "Missing value for --backend" >&2
          exit 1
        }
        case "$2" in
          tmpfs|apfs) TARGET_BACKEND=$2 ;;
          *)
            echo "Unsupported backend: $2" >&2
            exit 1
            ;;
        esac
        shift 2
        ;;
      --all)
        UNINSTALL_ALL=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [ "$UNINSTALL_ALL" = "1" ] && [ -n "$TARGET_BACKEND" ]; then
    echo "Use either --all or --backend, not both" >&2
    exit 1
  fi
}

effective_uid() {
  if [ -n "${MEMORY_CACHE_TEST_EFFECTIVE_UID:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_EFFECTIVE_UID"
  else
    id -u
  fi
}

resolve_target_user() {
  if [ -n "${MEMORY_CACHE_TEST_TARGET_USER:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_TARGET_USER"
    return
  fi

  if [ "$(effective_uid)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      printf '%s\n' "$SUDO_USER"
      return
    fi
  fi

  id -un
}

resolve_target_home() {
  if [ -n "${MEMORY_CACHE_TEST_TARGET_HOME:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_TARGET_HOME"
    return
  fi

  if [ "$(effective_uid)" -eq 0 ]; then
    dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    printf '%s\n' "$HOME"
  fi
}

resolve_target_uid() {
  if [ -n "${MEMORY_CACHE_TEST_TARGET_UID:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_TARGET_UID"
    return
  fi

  id -u "$1" 2>/dev/null || effective_uid
}

set_agent_paths() {
  AGENT_PLIST_PATH="$TARGET_HOME/Library/LaunchAgents/$LABEL.plist"
  AGENT_INSTALL_SCRIPT="$TARGET_HOME/.local/bin/create_memory_cache.sh"
  AGENT_CONFIG_PATH="$TARGET_HOME/.config/memory-cache-for-mac/config"
  AGENT_LOG_FILE="$TARGET_HOME/Library/Logs/memory-cache.log"
  AGENT_ERR_LOG_FILE="$TARGET_HOME/Library/Logs/memory-cache.err.log"
  OLD_AGENT_PLIST_PATH="$TARGET_HOME/Library/LaunchAgents/$OLD_LABEL.plist"
  OLD_AGENT_INSTALL_SCRIPT="$TARGET_HOME/.local/bin/create_ram_disk.sh"
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

agent_assets_exist() {
  [ -e "$AGENT_PLIST_PATH" ] ||
  [ -e "$AGENT_INSTALL_SCRIPT" ] ||
  [ -e "$AGENT_CONFIG_PATH" ] ||
  [ -e "$OLD_AGENT_PLIST_PATH" ] ||
  [ -e "$OLD_AGENT_INSTALL_SCRIPT" ]
}

resolve_uninstall_targets() {
  if [ "$UNINSTALL_ALL" = "1" ]; then
    UNINSTALL_APFS=1
    UNINSTALL_TMPFS=1
    return
  fi

  case "$TARGET_BACKEND" in
    apfs)
      UNINSTALL_APFS=1
      UNINSTALL_TMPFS=0
      return
      ;;
    tmpfs)
      UNINSTALL_APFS=0
      UNINSTALL_TMPFS=1
      return
      ;;
  esac

  if agent_assets_exist && daemon_assets_exist; then
    echo "Multiple backends are installed; choose --backend apfs, --backend tmpfs, or --all" >&2
    exit 1
  fi

  if agent_assets_exist; then
    UNINSTALL_APFS=1
    UNINSTALL_TMPFS=0
  elif daemon_assets_exist; then
    UNINSTALL_APFS=0
    UNINSTALL_TMPFS=1
  else
    UNINSTALL_APFS=1
    UNINSTALL_TMPFS=1
  fi
}

require_tmpfs_uninstall_privilege() {
  if [ "$UNINSTALL_TMPFS" != "1" ]; then
    return 0
  fi

  if ! daemon_assets_exist; then
    return 0
  fi

  if [ "$(effective_uid)" -ne 0 ]; then
    echo "tmpfs uninstall requires sudo because it removes a LaunchDaemon" >&2
    if [ "$UNINSTALL_ALL" = "1" ]; then
      echo "Run: sudo ./uninstall.sh --all" >&2
    else
      echo "Run: sudo ./uninstall.sh --backend tmpfs" >&2
    fi
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
  "$LAUNCHCTL_BIN" bootout "$domain" "$plist" >/dev/null 2>&1 || true
  "$LAUNCHCTL_BIN" bootout "$domain/$label" >/dev/null 2>&1 || true
}

AGENT_DOMAIN=""
DAEMON_DOMAIN="system"

uninstall_apfs() {
  bootout_if_needed "$AGENT_DOMAIN" "$LABEL" "$AGENT_PLIST_PATH"
  bootout_if_needed "$AGENT_DOMAIN" "$OLD_LABEL" "$OLD_AGENT_PLIST_PATH"
  rm -f "$AGENT_PLIST_PATH" "$AGENT_INSTALL_SCRIPT" "$AGENT_CONFIG_PATH"
  rm -f "$AGENT_LOG_FILE" "$AGENT_ERR_LOG_FILE"
  rm -f "$OLD_AGENT_PLIST_PATH" "$OLD_AGENT_INSTALL_SCRIPT"
}

uninstall_tmpfs() {
  bootout_if_needed "$DAEMON_DOMAIN" "$LABEL" "$DAEMON_PLIST_PATH"
  bootout_if_needed "$DAEMON_DOMAIN" "$OLD_LABEL" "$OLD_DAEMON_PLIST_PATH"
  rm -f "$DAEMON_PLIST_PATH" "$DAEMON_INSTALL_SCRIPT" "$DAEMON_CONFIG_PATH"
  rm -f "$DAEMON_LOG_FILE" "$DAEMON_ERR_LOG_FILE"
  rm -f "$OLD_DAEMON_PLIST_PATH" "$OLD_DAEMON_INSTALL_SCRIPT"
}

parse_args "$@"
TARGET_USER=$(resolve_target_user)
TARGET_HOME=$(resolve_target_home "$TARGET_USER")
[ -n "$TARGET_HOME" ] || { echo "Could not resolve target home for $TARGET_USER" >&2; exit 1; }
TARGET_UID=$(resolve_target_uid "$TARGET_USER")
set_agent_paths
AGENT_DOMAIN="gui/$TARGET_UID"
resolve_uninstall_targets
require_tmpfs_uninstall_privilege
if [ "$UNINSTALL_APFS" = "1" ]; then
  uninstall_apfs
fi
if [ "$UNINSTALL_TMPFS" = "1" ]; then
  uninstall_tmpfs
fi

echo "Uninstalled $LABEL"
echo "Manual cleanup, if desired:"
echo "  umount ~/tmpfs"
echo "  diskutil eject /Volumes/<APFS_DISK_NAME>"
echo "Mount roots are not unmounted or deleted automatically."
