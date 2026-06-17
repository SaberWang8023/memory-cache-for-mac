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

HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-uninstall.XXXXXX")/home
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Library/LaunchAgents" "$HOME_DIR/Library/Logs" "$HOME_DIR/.config/memory-cache-for-mac" "$HOME_DIR/tmpfs"

: > "$HOME_DIR/.local/bin/create_memory_cache.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
: > "$HOME_DIR/.config/memory-cache-for-mac/config"
: > "$HOME_DIR/.local/bin/create_ram_disk.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
: > "$HOME_DIR/Library/Logs/memory-cache.log"
: > "$HOME_DIR/Library/Logs/memory-cache.err.log"
echo "keep" > "$HOME_DIR/tmpfs/keep.txt"

MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/uninstall.sh" >/tmp/memory-cache-uninstall.out

assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
assert_absent "$HOME_DIR/.config/memory-cache-for-mac/config"
assert_absent "$HOME_DIR/.local/bin/create_ram_disk.sh"
assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
assert_absent "$HOME_DIR/Library/Logs/memory-cache.log"
assert_absent "$HOME_DIR/Library/Logs/memory-cache.err.log"
assert_dir "$HOME_DIR/tmpfs"
[ -f "$HOME_DIR/tmpfs/keep.txt" ] || fail "tmpfs contents were removed"
grep -Fq "Manual cleanup" /tmp/memory-cache-uninstall.out || fail "missing manual cleanup hint"

echo "uninstall tests passed"
