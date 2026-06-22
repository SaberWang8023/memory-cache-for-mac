#!/bin/sh

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_absent() {
  [ ! -e "$1" ] || fail "expected absent: $1"
}

assert_dir() {
  [ -d "$1" ] || fail "expected directory: $1"
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

run_dual_mode_cleanup_test() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-uninstall.XXXXXX")
  HOME_DIR="$TEST_ROOT/home"
  SYSTEM_ROOT="$TEST_ROOT/system"
  OUTPUT_FILE="$TEST_ROOT/uninstall.out"

  mkdir -p \
    "$HOME_DIR/.local/bin" \
    "$HOME_DIR/Library/LaunchAgents" \
    "$HOME_DIR/Library/Logs" \
    "$HOME_DIR/.config/memory-cache-for-mac" \
    "$HOME_DIR/tmpfs" \
    "$SYSTEM_ROOT/Library/LaunchDaemons" \
    "$SYSTEM_ROOT/usr/local/libexec" \
    "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac" \
    "$SYSTEM_ROOT/Library/Logs"

  : > "$HOME_DIR/.local/bin/create_memory_cache.sh"
  : > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  : > "$HOME_DIR/.config/memory-cache-for-mac/config"
  : > "$HOME_DIR/.local/bin/create_ram_disk.sh"
  : > "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
  : > "$HOME_DIR/Library/Logs/memory-cache.log"
  : > "$HOME_DIR/Library/Logs/memory-cache.err.log"

  : > "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  : > "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
  : > "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
  : > "$SYSTEM_ROOT/Library/Logs/memory-cache.log"
  : > "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"
  : > "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
  : > "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.ramdisk.plist"

  echo "keep" > "$HOME_DIR/tmpfs/keep.txt"
  echo "user-data" > "$HOME_DIR/.config/memory-cache-for-mac/user-note.txt"

  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
  MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
  HOME="$HOME_DIR" \
  "$ROOT/uninstall.sh" >"$OUTPUT_FILE"

  assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  assert_absent "$HOME_DIR/.config/memory-cache-for-mac/config"
  assert_absent "$HOME_DIR/.local/bin/create_ram_disk.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
  assert_absent "$HOME_DIR/Library/Logs/memory-cache.log"
  assert_absent "$HOME_DIR/Library/Logs/memory-cache.err.log"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_absent "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
  assert_absent "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
  assert_absent "$SYSTEM_ROOT/Library/Logs/memory-cache.log"
  assert_absent "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
  assert_absent "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.ramdisk.plist"
  assert_dir "$HOME_DIR/tmpfs"
  [ -f "$HOME_DIR/tmpfs/keep.txt" ] || fail "tmpfs contents were removed"
  [ -f "$HOME_DIR/.config/memory-cache-for-mac/user-note.txt" ] || fail "user config directory contents were removed"
  grep -Fq "Manual cleanup" "$OUTPUT_FILE" || fail "missing manual cleanup hint"
  grep -Fq "diskutil eject /Volumes/<APFS_DISK_NAME>" "$OUTPUT_FILE" || fail "missing APFS cleanup hint"
}

run_daemon_requires_sudo_test() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-uninstall-sudo.XXXXXX")
  HOME_DIR="$TEST_ROOT/home"
  REAL_SYSTEM_ROOT="$TEST_ROOT/real-root"
  STDERR_FILE="$TEST_ROOT/stderr.out"

  mkdir -p \
    "$HOME_DIR/.local/bin" \
    "$HOME_DIR/Library/LaunchAgents" \
    "$HOME_DIR/.config/memory-cache-for-mac" \
    "$REAL_SYSTEM_ROOT/Library/LaunchDaemons"

  : > "$HOME_DIR/.local/bin/create_memory_cache.sh"
  : > "$REAL_SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"

  if MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_DAEMON_PROBE_ROOT="$REAL_SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=501 \
    HOME="$HOME_DIR" \
    "$ROOT/uninstall.sh" >/dev/null 2>"$STDERR_FILE"; then
    fail "expected daemon uninstall without sudo to fail"
  fi

  grep -Fq "Daemon uninstall requires sudo" "$STDERR_FILE" || fail "missing sudo error"
  assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_file "$REAL_SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
}

run_dual_mode_cleanup_test
run_daemon_requires_sudo_test

echo "uninstall tests passed"
