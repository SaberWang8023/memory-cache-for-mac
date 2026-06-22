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
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --backend tmpfs >/tmp/memory-cache-install-tmpfs-no-root.out 2>&1; then
  fail "tmpfs install without root unexpectedly succeeded"
fi
grep -Fq "tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root" \
  /tmp/memory-cache-install-tmpfs-no-root.out || fail "missing tmpfs sudo error"

HOME_DIR=$(make_home)
SANDBOX_ROOT=$(dirname "$HOME_DIR")
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=25769803776 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER=saber \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend tmpfs --size 2g >/tmp/memory-cache-install-daemon.out

DAEMON_CONFIG="$SANDBOX_ROOT/Library/Application Support/memory-cache-for-mac/config"
assert_file "$DAEMON_CONFIG"
assert_contains "$DAEMON_CONFIG" "BACKEND=tmpfs"
assert_contains "$DAEMON_CONFIG" "CACHE_SIZE=2g"
assert_contains "$DAEMON_CONFIG" "SERVICE_MODE=daemon"
assert_contains "$DAEMON_CONFIG" "TARGET_USER=saber"
assert_contains "$DAEMON_CONFIG" "TARGET_HOME=$HOME_DIR"
assert_contains "$DAEMON_CONFIG" "TMPFS_MOUNT_PATH=\"$HOME_DIR/tmpfs\""
assert_file "$SANDBOX_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_file "$SANDBOX_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"

HOME_DIR=$(make_home)
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=17179869184 \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend apfs >/tmp/memory-cache-install-agent.out

AGENT_CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
assert_file "$AGENT_CONFIG"
assert_contains "$AGENT_CONFIG" "BACKEND=apfs"
assert_contains "$AGENT_CONFIG" "CACHE_SIZE=512m"
assert_contains "$AGENT_CONFIG" "SERVICE_MODE=agent"
assert_contains "$AGENT_CONFIG" "TARGET_HOME=$HOME_DIR"
assert_contains "$AGENT_CONFIG" "APFS_MOUNT_PATH=\"/Volumes/\$APFS_DISK_NAME\""
assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"

HOME_DIR=$(make_home)
SANDBOX_ROOT=$(dirname "$HOME_DIR")
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Library/LaunchAgents" "$SANDBOX_ROOT/Library/LaunchDaemons" "$SANDBOX_ROOT/usr/local/libexec"
: > "$HOME_DIR/.local/bin/create_memory_cache.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
: > "$SANDBOX_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
: > "$SANDBOX_ROOT/usr/local/libexec/create_memory_cache.sh"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER=saber \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend apfs --size 1g >/tmp/memory-cache-install-switch-to-agent.out
assert_not_exists "$SANDBOX_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
assert_not_exists "$SANDBOX_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"

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
