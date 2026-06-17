#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

CONFIG_PATH="${MEMORY_CACHE_CONFIG_PATH:-$HOME/.config/memory-cache-for-mac/config}"

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
  mount | grep -Fq " on $path "
}

ensure_child_dirs() {
  root=$1
  for dir in $CREATE_DIRS; do
    mkdir -p "$root/$dir"
  done
}

load_config() {
  [ -f "$CONFIG_PATH" ] || fail "Missing config: $CONFIG_PATH. Re-run ./install.sh."
  # shellcheck disable=SC1090
  . "$CONFIG_PATH"

  BACKEND=${BACKEND:-}
  CACHE_SIZE=${CACHE_SIZE:-}
  TMPFS_MOUNT_PATH=${TMPFS_MOUNT_PATH:-"$HOME/tmpfs"}
  APFS_DISK_NAME=${APFS_DISK_NAME:-Ramdisk}
  APFS_MOUNT_PATH=${APFS_MOUNT_PATH:-"/Volumes/$APFS_DISK_NAME"}
  CREATE_DIRS=${CREATE_DIRS:-"Downloads Cache/Chrome Cache/Music"}

  case "$BACKEND" in
    tmpfs|apfs) ;;
    *) fail "Unsupported backend: $BACKEND" ;;
  esac

  CACHE_SIZE=$(normalize_size "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
}

mount_tmpfs_backend() {
  command -v mount_tmpfs >/dev/null 2>&1 || fail "tmpfs backend requires mount_tmpfs"

  if is_mounted_at "$TMPFS_MOUNT_PATH"; then
    ensure_child_dirs "$TMPFS_MOUNT_PATH"
    echo "Memory cache is already mounted at $TMPFS_MOUNT_PATH"
    return
  fi

  if [ -d "$TMPFS_MOUNT_PATH" ] && [ -n "$(ls -A "$TMPFS_MOUNT_PATH" 2>/dev/null)" ]; then
    fail "Refusing to mount over non-empty directory: $TMPFS_MOUNT_PATH"
  fi

  mkdir -p "$TMPFS_MOUNT_PATH"
  mount_tmpfs -i -s "$CACHE_SIZE" "$TMPFS_MOUNT_PATH" || fail "mount_tmpfs failed"
  ensure_child_dirs "$TMPFS_MOUNT_PATH"
}

mount_apfs_backend() {
  if is_mounted_at "$APFS_MOUNT_PATH"; then
    ensure_child_dirs "$APFS_MOUNT_PATH"
    echo "Memory cache is already mounted at $APFS_MOUNT_PATH"
    return
  fi

  if [ -d "$APFS_MOUNT_PATH" ] && [ -z "$(ls -A "$APFS_MOUNT_PATH" 2>/dev/null)" ]; then
    rmdir "$APFS_MOUNT_PATH"
  fi

  blocks=$(size_to_blocks "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
  DISK_ID=$(hdiutil attach -nomount "ram://$blocks" | awk 'NR==1 { print $1 }') || fail "hdiutil attach failed"
  [ -n "$DISK_ID" ] || fail "Could not get ramdisk device id"

  diskutil partitionDisk "$DISK_ID" GPT APFS "$APFS_DISK_NAME" 0 || fail "diskutil partitionDisk failed"
  [ -d "$APFS_MOUNT_PATH" ] || fail "Could not find $APFS_MOUNT_PATH"
  ensure_child_dirs "$APFS_MOUNT_PATH"
}

load_config
case "$BACKEND" in
  tmpfs) mount_tmpfs_backend ;;
  apfs) mount_apfs_backend ;;
esac
