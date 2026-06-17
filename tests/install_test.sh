#!/bin/sh

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  file=$1
  expected=$2
  grep -Fq "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected absent: $1"
}

make_home() {
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-install.XXXXXX")
  mkdir -p "$tmp/home"
  printf '%s\n' "$tmp/home"
}

HOME_DIR=$(make_home)
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=17179869184 \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend tmpfs >/tmp/memory-cache-install-1.out

CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
assert_file "$CONFIG"
assert_contains "$CONFIG" "BACKEND=tmpfs"
assert_contains "$CONFIG" "CACHE_SIZE=512m"
assert_contains "$CONFIG" "TMPFS_MOUNT_PATH=\"\$HOME/tmpfs\""
assert_contains "$CONFIG" "CREATE_DIRS=\"Downloads Cache/Chrome Cache/Music\""
assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"

HOME_DIR=$(make_home)
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=25769803776 \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend apfs --size 2g >/tmp/memory-cache-install-2.out

CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
assert_file "$CONFIG"
assert_contains "$CONFIG" "BACKEND=apfs"
assert_contains "$CONFIG" "CACHE_SIZE=2g"
assert_contains "$CONFIG" "APFS_MOUNT_PATH=\"/Volumes/\$APFS_DISK_NAME\""

HOME_DIR=$(make_home)
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Library/LaunchAgents"
: > "$HOME_DIR/.local/bin/create_ram_disk.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend apfs --size 1g >/tmp/memory-cache-install-3.out
assert_not_exists "$HOME_DIR/.local/bin/create_ram_disk.sh"
assert_not_exists "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"

HOME_DIR=$(make_home)
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --backend invalid >/tmp/memory-cache-install-bad-backend.out 2>&1; then
  fail "invalid backend unexpectedly succeeded"
fi
grep -Fq "Unsupported backend" /tmp/memory-cache-install-bad-backend.out || fail "missing invalid backend error"

HOME_DIR=$(make_home)
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --size banana >/tmp/memory-cache-install-bad-size.out 2>&1; then
  fail "invalid size unexpectedly succeeded"
fi
grep -Fq "Unsupported cache size" /tmp/memory-cache-install-bad-size.out || fail "missing invalid size error"

echo "install tests passed"
