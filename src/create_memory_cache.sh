#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if [ "${MEMORY_CACHE_TEST_COMMANDS:-0}" = "1" ]; then
  MOUNT_TMPFS_CMD=${MOUNT_TMPFS_CMD:-mount_tmpfs}
  HDIUTIL_CMD=${HDIUTIL_CMD:-hdiutil}
  DISKUTIL_CMD=${DISKUTIL_CMD:-diskutil}
  MOUNT_CMD=${MOUNT_CMD:-mount}
  CHOWN_CMD=${CHOWN_CMD:-chown}
else
  MOUNT_TMPFS_CMD=mount_tmpfs
  HDIUTIL_CMD=hdiutil
  DISKUTIL_CMD=diskutil
  MOUNT_CMD=mount
  CHOWN_CMD=chown
fi

fail() {
  echo "$*" >&2
  exit 1
}

runtime_daemon_config_path() {
  script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)

  case "$script_dir" in
    */usr/local/libexec)
      system_root=${script_dir%/usr/local/libexec}
      printf '%s\n' "$system_root/Library/Application Support/memory-cache-for-mac/config"
      return
      ;;
  esac

  printf '%s\n' "/Library/Application Support/memory-cache-for-mac/config"
}

is_daemon_runtime_context() {
  script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)

  case "$script_dir" in
    */usr/local/libexec) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_size() {
  size=$1
  case "$size" in
    *[mMgG]) ;;
    *) return 1 ;;
  esac
  number=${size%?}
  suffix=${size#"$number"}
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$number" -gt 0 ] || return 1
  case "$suffix" in
    m|M) printf '%sm\n' "$number" ;;
    g|G) printf '%sg\n' "$number" ;;
    *) return 1 ;;
  esac
}

size_to_blocks() {
  normalized=$(normalize_size "$1") || return 1
  number=${normalized%?}
  suffix=${normalized#"$number"}
  case "$suffix" in
    m) bytes=$((number * 1024 * 1024)) ;;
    g) bytes=$((number * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$((bytes / 512))"
}

is_mounted_at() {
  path=$1
  "$MOUNT_CMD" | grep -Fq " on $path "
}

ensure_child_dirs() {
  root=$1
  for dir in $CREATE_DIRS; do
    mkdir -p "$root/$dir"
  done
}

chown_path_if_needed() {
  path=$1

  case "${SERVICE_MODE:-}" in
    daemon) ;;
    *) return 0 ;;
  esac

  [ -n "${TARGET_USER:-}" ] || return 0
  "$CHOWN_CMD" "$TARGET_USER" "$path" >/dev/null 2>&1 || fail "Failed to set ownership on $path"
}

fix_tmpfs_ownership() {
  chown_path_if_needed "$TMPFS_MOUNT_PATH"

  for dir in $CREATE_DIRS; do
    chown_path_if_needed "$TMPFS_MOUNT_PATH/$dir"
  done
}

require_config_var() {
  var_name=$1
  eval "is_set=\${$var_name+x}"
  [ "$is_set" = x ] || fail "Missing required config: $var_name"
  eval "value=\${$var_name}"
  [ -n "$value" ] || fail "Missing required config: $var_name"
}

validate_apfs_disk_name() {
  case "$APFS_DISK_NAME" in
    .|..) fail "Unsupported APFS_DISK_NAME: must be a single volume name" ;;
  esac

  if printf '%s' "$APFS_DISK_NAME" | LC_ALL=C grep '[[:cntrl:]:/]' >/dev/null 2>&1; then
    fail "Unsupported APFS_DISK_NAME: must be a single volume name"
  fi
}

resolve_default_config_path() {
  daemon_config_path=$(runtime_daemon_config_path)
  user_config_path="$HOME/.config/memory-cache-for-mac/config"

  if [ -n "${MEMORY_CACHE_CONFIG_PATH:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_CONFIG_PATH"
    return
  fi

  if is_daemon_runtime_context; then
    printf '%s\n' "$daemon_config_path"
    return
  fi

  if [ -f "$user_config_path" ]; then
    printf '%s\n' "$user_config_path"
    return
  fi

  printf '%s\n' "$user_config_path"
}

load_config_from() {
  config_path=$1

  [ -f "$config_path" ] || fail "Missing config: $config_path. Re-run ./install.sh."
  unset BACKEND CACHE_SIZE TMPFS_MOUNT_PATH APFS_DISK_NAME APFS_MOUNT_PATH CREATE_DIRS
  unset SERVICE_MODE TARGET_USER TARGET_HOME
  # shellcheck disable=SC1090
  . "$config_path"

  require_config_var BACKEND
  require_config_var SERVICE_MODE
  require_config_var CACHE_SIZE
  require_config_var TARGET_USER
  require_config_var TARGET_HOME
  require_config_var TMPFS_MOUNT_PATH
  require_config_var APFS_DISK_NAME
  require_config_var APFS_MOUNT_PATH
  require_config_var CREATE_DIRS

  case "$SERVICE_MODE" in
    agent|daemon) ;;
    *) fail "Unsupported service mode: $SERVICE_MODE" ;;
  esac

  case "$BACKEND" in
    tmpfs|apfs) ;;
    *) fail "Unsupported backend: $BACKEND" ;;
  esac

  CACHE_SIZE=$(normalize_size "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"

  if [ "$BACKEND" = "apfs" ]; then
    validate_apfs_disk_name
    expected_apfs_mount_path="/Volumes/$APFS_DISK_NAME"
    [ "$APFS_MOUNT_PATH" = "$expected_apfs_mount_path" ] || fail "APFS_MOUNT_PATH must match $expected_apfs_mount_path for apfs backend"
  fi
}

load_config() {
  CONFIG_PATH=$(resolve_default_config_path)
  load_config_from "$CONFIG_PATH"
}

mount_tmpfs_backend() {
  command -v "$MOUNT_TMPFS_CMD" >/dev/null 2>&1 || fail "tmpfs backend requires mount_tmpfs"

  if is_mounted_at "$TMPFS_MOUNT_PATH"; then
    ensure_child_dirs "$TMPFS_MOUNT_PATH"
    fix_tmpfs_ownership
    echo "Memory cache is already mounted at $TMPFS_MOUNT_PATH"
    return
  fi

  if [ -d "$TMPFS_MOUNT_PATH" ] && [ -n "$(ls -A "$TMPFS_MOUNT_PATH" 2>/dev/null)" ]; then
    fail "Refusing to mount over non-empty directory: $TMPFS_MOUNT_PATH"
  fi

  mkdir -p "$TMPFS_MOUNT_PATH"
  "$MOUNT_TMPFS_CMD" -i -s "$CACHE_SIZE" "$TMPFS_MOUNT_PATH" || fail "mount_tmpfs failed"
  ensure_child_dirs "$TMPFS_MOUNT_PATH"
  fix_tmpfs_ownership
}

mount_apfs_backend() {
  if is_mounted_at "$APFS_MOUNT_PATH"; then
    ensure_child_dirs "$APFS_MOUNT_PATH"
    echo "Memory cache is already mounted at $APFS_MOUNT_PATH"
    return
  fi

  if [ -d "$APFS_MOUNT_PATH" ]; then
    if [ -n "$(ls -A "$APFS_MOUNT_PATH" 2>/dev/null)" ]; then
      fail "Refusing to mount over non-empty directory: $APFS_MOUNT_PATH"
    fi
    rmdir "$APFS_MOUNT_PATH"
  fi

  blocks=$(size_to_blocks "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
  DISK_ID=$("$HDIUTIL_CMD" attach -nomount "ram://$blocks" | awk 'NR==1 { print $1 }') || fail "hdiutil attach failed"
  [ -n "$DISK_ID" ] || fail "Could not get ramdisk device id"

  if ! "$DISKUTIL_CMD" partitionDisk "$DISK_ID" GPT APFS "$APFS_DISK_NAME" 0; then
    "$HDIUTIL_CMD" detach "$DISK_ID" >/dev/null 2>&1 || true
    fail "diskutil partitionDisk failed"
  fi
  if ! is_mounted_at "$APFS_MOUNT_PATH"; then
    "$HDIUTIL_CMD" detach "$DISK_ID" >/dev/null 2>&1 || true
    fail "APFS volume was not mounted at $APFS_MOUNT_PATH"
  fi
  ensure_child_dirs "$APFS_MOUNT_PATH"
}

load_config
case "$BACKEND" in
  tmpfs) mount_tmpfs_backend ;;
  apfs) mount_apfs_backend ;;
esac
