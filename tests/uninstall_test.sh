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

make_uninstall_fixture() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-uninstall.XXXXXX")
  HOME_DIR="$TEST_ROOT/home"
  SYSTEM_ROOT="$TEST_ROOT/system"
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
}

seed_agent_assets() {
  : > "$HOME_DIR/.local/bin/create_memory_cache.sh"
  : > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  : > "$HOME_DIR/.config/memory-cache-for-mac/config"
  : > "$HOME_DIR/.local/bin/create_ram_disk.sh"
  : > "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
  : > "$HOME_DIR/Library/Logs/memory-cache.log"
  : > "$HOME_DIR/Library/Logs/memory-cache.err.log"
}

seed_daemon_assets() {
  : > "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  : > "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
  : > "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
  : > "$SYSTEM_ROOT/Library/Logs/memory-cache.log"
  : > "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"
  : > "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
  : > "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.ramdisk.plist"
}

run_backend_apfs_only_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
  MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
  HOME="$HOME_DIR" \
    "$ROOT/uninstall.sh" --backend apfs >/tmp/memory-cache-uninstall-apfs.out

  assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  assert_absent "$HOME_DIR/.config/memory-cache-for-mac/config"
  assert_absent "$HOME_DIR/.local/bin/create_ram_disk.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
  assert_absent "$HOME_DIR/Library/Logs/memory-cache.log"
  assert_absent "$HOME_DIR/Library/Logs/memory-cache.err.log"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_file "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
  assert_file "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
  assert_file "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.ramdisk.plist"
  assert_file "$SYSTEM_ROOT/Library/Logs/memory-cache.log"
  assert_file "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"
}

run_backend_tmpfs_only_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
  HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" --backend tmpfs >/tmp/memory-cache-uninstall-tmpfs.out
  assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  assert_file "$HOME_DIR/.config/memory-cache-for-mac/config"
  assert_file "$HOME_DIR/.local/bin/create_ram_disk.sh"
  assert_file "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
  assert_file "$HOME_DIR/Library/Logs/memory-cache.log"
  assert_file "$HOME_DIR/Library/Logs/memory-cache.err.log"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_absent "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
  assert_absent "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
  assert_absent "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.ramdisk.plist"
  assert_absent "$SYSTEM_ROOT/Library/Logs/memory-cache.log"
  assert_absent "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"
}

run_all_requires_sudo_without_partial_delete_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  STDERR_FILE="$TEST_ROOT/stderr.out"
  if MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_DAEMON_PROBE_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=501 \
    HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" --all >/dev/null 2>"$STDERR_FILE"; then
    fail "--all without sudo unexpectedly succeeded"
  fi
  grep -Fq "tmpfs uninstall requires sudo because it removes a LaunchDaemon" "$STDERR_FILE" || fail "missing --all sudo error"
  assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
}

run_default_requires_choice_when_both_exist_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  STDERR_FILE="$TEST_ROOT/default-both.err"
  if MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
    HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" >/dev/null 2>"$STDERR_FILE"; then
    fail "default uninstall with both backends unexpectedly succeeded"
  fi
  grep -Fq "Multiple backends are installed" "$STDERR_FILE" || fail "missing multiple backend error"
  assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
}

run_default_apfs_only_test() {
  make_uninstall_fixture
  seed_agent_assets
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=501 \
    HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" >/tmp/memory-cache-uninstall-default-apfs.out

  assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  assert_absent "$HOME_DIR/.config/memory-cache-for-mac/config"
  assert_absent "$HOME_DIR/.local/bin/create_ram_disk.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
  assert_absent "$HOME_DIR/Library/Logs/memory-cache.log"
  assert_absent "$HOME_DIR/Library/Logs/memory-cache.err.log"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
}

run_default_tmpfs_requires_sudo_test() {
  make_uninstall_fixture
  seed_daemon_assets
  STDERR_FILE="$TEST_ROOT/default-tmpfs.err"
  if MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_DAEMON_PROBE_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=501 \
    HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" >/dev/null 2>"$STDERR_FILE"; then
    fail "default uninstall with tmpfs only unexpectedly succeeded without sudo"
  fi
  grep -Fq "tmpfs uninstall requires sudo because it removes a LaunchDaemon" "$STDERR_FILE" || fail "missing default tmpfs sudo error"
  grep -Fq "Run: sudo ./uninstall.sh --backend tmpfs" "$STDERR_FILE" || fail "missing default tmpfs sudo hint"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_file "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
  assert_file "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
  assert_file "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.ramdisk.plist"
  assert_file "$SYSTEM_ROOT/Library/Logs/memory-cache.log"
  assert_file "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"
}

run_default_compat_cleanup_without_backends_test() {
  make_uninstall_fixture
  echo "keep" > "$HOME_DIR/tmpfs/keep.txt"
  echo "note" > "$HOME_DIR/.config/memory-cache-for-mac/user-note.txt"
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=501 \
    HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" >/tmp/memory-cache-uninstall-default-empty.out

  assert_dir "$HOME_DIR/tmpfs"
  [ -f "$HOME_DIR/tmpfs/keep.txt" ] || fail "tmpfs contents were removed without installed backends"
  [ -f "$HOME_DIR/.config/memory-cache-for-mac/user-note.txt" ] || fail "user config directory contents were removed without installed backends"
  assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_absent "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
}

run_all_root_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  echo "keep" > "$HOME_DIR/tmpfs/keep.txt"
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
  MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
  MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
  HOME="$HOME_DIR" \
    "$ROOT/uninstall.sh" --all >/tmp/memory-cache-uninstall-all.out
  assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_dir "$HOME_DIR/tmpfs"
  [ -f "$HOME_DIR/tmpfs/keep.txt" ] || fail "tmpfs contents were removed"
}

run_backend_apfs_only_test
run_backend_tmpfs_only_test
run_all_requires_sudo_without_partial_delete_test
run_default_requires_choice_when_both_exist_test
run_default_apfs_only_test
run_default_tmpfs_requires_sudo_test
run_default_compat_cleanup_without_backends_test
run_all_root_test

echo "uninstall tests passed"
