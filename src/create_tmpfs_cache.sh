#!/bin/sh

MEMORY_CACHE_INSTALLED=0

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if [ "${MEMORY_CACHE_TEST_COMMANDS:-0}" = "1" ]; then
  MOUNT_TMPFS_CMD=${MOUNT_TMPFS_CMD:-mount_tmpfs}
  MOUNT_CMD=${MOUNT_CMD:-mount}
  CHOWN_CMD=${CHOWN_CMD:-chown}
else
  MOUNT_TMPFS_CMD=mount_tmpfs
  MOUNT_CMD=mount
  CHOWN_CMD=chown
fi

fail() {
  echo "$*" >&2
  exit 1
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

require_installed_constant() {
  var_name=$1
  eval "is_set=\${$var_name+x}"
  [ "$is_set" = x ] || fail "Missing installed constant: $var_name"
  eval "value=\${$var_name}"
  [ -n "$value" ] || fail "Missing installed constant: $var_name"
}

chown_path_if_needed() {
  path=$1
  [ -n "${TARGET_USER:-}" ] || return 0
  "$CHOWN_CMD" "$TARGET_USER" "$path" >/dev/null 2>&1 || fail "Failed to set ownership on $path"
}

fix_tmpfs_ownership() {
  chown_path_if_needed "$TMPFS_MOUNT_PATH"

  for dir in $CREATE_DIRS; do
    chown_path_if_needed "$TMPFS_MOUNT_PATH/$dir"
  done
}

load_installed_config() {
  require_installed_constant MEMORY_CACHE_INSTALLED
  require_installed_constant CACHE_SIZE
  require_installed_constant TARGET_USER
  require_installed_constant TARGET_HOME
  [ "$MEMORY_CACHE_INSTALLED" = "1" ] || fail "Missing installed constant: MEMORY_CACHE_INSTALLED"
  CACHE_SIZE=$(normalize_size "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
  TMPFS_MOUNT_PATH="$TARGET_HOME/tmpfs"
  CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
}

mount_tmpfs_cache() {
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

load_installed_config
mount_tmpfs_cache
