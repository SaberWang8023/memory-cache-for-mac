#!/bin/sh

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
TMPFS_SOURCE_SCRIPT="$ROOT/src/create_tmpfs_cache.sh"
APFS_SOURCE_SCRIPT="$ROOT/src/create_apfs_cache.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_exists() {
  [ -e "$1" ] || fail "expected present: $1"
}

assert_contains() {
  file=$1
  expected=$2
  grep -Fq "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_contains() {
  file=$1
  unexpected=$2
  if grep -Fq "$unexpected" "$file"; then
    fail "unexpected '$unexpected' in $file"
  fi
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected absent: $1"
}

make_home() {
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-install.XXXXXX")
  mkdir -p "$tmp/home"
  printf '%s\n' "$tmp/home"
}

make_sandbox_root() {
  mktemp -d "${TMPDIR:-/tmp}/memory-cache-install.XXXXXX"
}

HOME_DIR=$(make_home)
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --backend tmpfs >/tmp/memory-cache-install-tmpfs-no-root.out 2>&1; then
  fail "tmpfs install without root unexpectedly succeeded"
fi
grep -Fq "tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root" \
  /tmp/memory-cache-install-tmpfs-no-root.out || fail "missing tmpfs sudo error"

HOME_DIR=$(make_home)
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --backend tmpfs --size banana >/tmp/memory-cache-install-tmpfs-sudo-before-size.out 2>&1; then
  fail "tmpfs install without root and invalid size unexpectedly succeeded"
fi
grep -Fq "tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root" \
  /tmp/memory-cache-install-tmpfs-sudo-before-size.out || fail "tmpfs did not ask for sudo before checking size"
if grep -Fq "Unsupported cache size" /tmp/memory-cache-install-tmpfs-sudo-before-size.out; then
  fail "tmpfs checked size before asking for sudo"
fi

assert_contains "$TMPFS_SOURCE_SCRIPT" "MEMORY_CACHE_INSTALLED=0"
assert_contains "$APFS_SOURCE_SCRIPT" "MEMORY_CACHE_INSTALLED=0"

SANDBOX_ROOT=$(make_sandbox_root)
HOME_DIR="$SANDBOX_ROOT/home"
SYSTEM_ROOT="$SANDBOX_ROOT/system"
mkdir -p "$HOME_DIR" "$SYSTEM_ROOT"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=25769803776 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER=saber \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend tmpfs --size 2g >/tmp/memory-cache-install-daemon.out

DAEMON_CONFIG="$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
assert_not_exists "$DAEMON_CONFIG"
DAEMON_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_file "$DAEMON_SCRIPT"
assert_contains "$DAEMON_SCRIPT" "MEMORY_CACHE_INSTALLED='1'"
[ "$(grep -Fc "MEMORY_CACHE_INSTALLED=0" "$DAEMON_SCRIPT")" -eq 0 ] || fail "daemon runtime kept source install sentinel"
assert_contains "$DAEMON_SCRIPT" "BACKEND='tmpfs'"
assert_contains "$DAEMON_SCRIPT" "CACHE_SIZE='2g'"
assert_contains "$DAEMON_SCRIPT" "SERVICE_MODE='daemon'"
assert_contains "$DAEMON_SCRIPT" "TARGET_USER='saber'"
assert_contains "$DAEMON_SCRIPT" "TARGET_HOME='$HOME_DIR'"
assert_contains "$DAEMON_SCRIPT" "mount_tmpfs"
assert_not_exists "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
if grep -Fq "hdiutil" "$DAEMON_SCRIPT" || grep -Fq "diskutil" "$DAEMON_SCRIPT" || grep -Fq "APFS_MOUNT_PATH" "$DAEMON_SCRIPT"; then
  fail "daemon runtime contains APFS logic"
fi
DAEMON_PLIST="$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
assert_file "$DAEMON_PLIST"
assert_contains "$DAEMON_PLIST" "/usr/local/libexec/create_memory_cache.sh"
assert_contains "$DAEMON_PLIST" "/Library/Logs/memory-cache.log"
assert_contains "$DAEMON_PLIST" "/Library/Logs/memory-cache.err.log"

QUOTE_SNIPPET=$(mktemp "${TMPDIR:-/tmp}/memory-cache-quote.XXXXXX")
sed -n '/^quote_shell_value() {$/,/^}$/p' "$ROOT/install.sh" > "$QUOTE_SNIPPET"
. "$QUOTE_SNIPPET"
quoted_value=$(
  sed() {
    fail "quote_shell_value unexpectedly invoked sed"
  }
  quote_shell_value "saber'qa"
)
[ "$quoted_value" = "'saber'\\''qa'" ] || fail "quote_shell_value returned unexpected literal: $quoted_value"

SANDBOX_ROOT=$(make_sandbox_root)
HOME_DIR="$SANDBOX_ROOT/home with ' quote"
SYSTEM_ROOT="$SANDBOX_ROOT/system"
mkdir -p "$HOME_DIR" "$SYSTEM_ROOT"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=25769803776 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER="saber'qa" \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend tmpfs --size 2g >/tmp/memory-cache-install-daemon-quoted.out

QUOTED_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_file "$QUOTED_SCRIPT"
QUOTED_CONSTS=$(mktemp "${TMPDIR:-/tmp}/memory-cache-install-quoted.XXXXXX")
sed -n '3,9p' "$QUOTED_SCRIPT" > "$QUOTED_CONSTS"
unset MEMORY_CACHE_INSTALLED BACKEND CACHE_SIZE SERVICE_MODE TARGET_USER TARGET_HOME
. "$QUOTED_CONSTS"
[ "$MEMORY_CACHE_INSTALLED" = "1" ] || fail "install marker did not round-trip"
[ "$BACKEND" = "tmpfs" ] || fail "quoted BACKEND did not round-trip"
[ "$CACHE_SIZE" = "2g" ] || fail "quoted CACHE_SIZE did not round-trip"
[ "$SERVICE_MODE" = "daemon" ] || fail "quoted SERVICE_MODE did not round-trip"
[ "$TARGET_USER" = "saber'qa" ] || fail "quoted TARGET_USER did not round-trip"
[ "$TARGET_HOME" = "$HOME_DIR" ] || fail "quoted TARGET_HOME did not round-trip"

HOME_DIR=$(make_home)
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=17179869184 \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend apfs >/tmp/memory-cache-install-agent.out

AGENT_CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
assert_not_exists "$AGENT_CONFIG"
AGENT_SCRIPT="$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_file "$AGENT_SCRIPT"
assert_contains "$AGENT_SCRIPT" "MEMORY_CACHE_INSTALLED='1'"
[ "$(grep -Fc "MEMORY_CACHE_INSTALLED=0" "$AGENT_SCRIPT")" -eq 0 ] || fail "agent runtime kept source install sentinel"
assert_contains "$AGENT_SCRIPT" "BACKEND='apfs'"
assert_contains "$AGENT_SCRIPT" "CACHE_SIZE='512m'"
assert_contains "$AGENT_SCRIPT" "SERVICE_MODE='agent'"
assert_contains "$AGENT_SCRIPT" "hdiutil"
assert_contains "$AGENT_SCRIPT" "diskutil"
assert_not_contains "$AGENT_SCRIPT" "mount_tmpfs"
assert_not_contains "$AGENT_SCRIPT" "TMPFS_MOUNT_PATH"
assert_not_contains "$AGENT_SCRIPT" "TARGET_HOME="
assert_not_contains "$AGENT_SCRIPT" "TARGET_USER="
AGENT_PLIST="$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
assert_file "$AGENT_PLIST"
assert_contains "$AGENT_PLIST" "$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_contains "$AGENT_PLIST" "$HOME_DIR/Library/Logs/memory-cache.log"
assert_contains "$AGENT_PLIST" "$HOME_DIR/Library/Logs/memory-cache.err.log"

SANDBOX_ROOT=$(make_sandbox_root)
HOME_DIR="$SANDBOX_ROOT/home"
SYSTEM_ROOT="$SANDBOX_ROOT/system"
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Library/LaunchAgents" "$SYSTEM_ROOT/Library/LaunchDaemons" "$SYSTEM_ROOT/usr/local/libexec"
mkdir -p "$HOME_DIR/.config/memory-cache-for-mac" "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac"
: > "$HOME_DIR/.local/bin/create_memory_cache.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
: > "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
: > "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
: > "$HOME_DIR/.config/memory-cache-for-mac/config"
: > "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER=saber \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend apfs --size 1g >/tmp/memory-cache-install-switch-to-agent.out
assert_file "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_not_exists "$HOME_DIR/.config/memory-cache-for-mac/config"
assert_exists "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"

printf '%s\n' "agent keep" > "$HOME_DIR/.local/bin/create_memory_cache.sh"
: > "$HOME_DIR/.config/memory-cache-for-mac/config"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER=saber \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
HOME="$HOME_DIR" \
  "$ROOT/install.sh" --backend tmpfs --size 512m >/tmp/memory-cache-install-repeat-tmpfs.out
assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
grep -Fq "agent keep" "$HOME_DIR/.local/bin/create_memory_cache.sh" || fail "repeat tmpfs install changed agent script"
assert_contains "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh" "CACHE_SIZE='512m'"
assert_not_exists "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
assert_exists "$HOME_DIR/.config/memory-cache-for-mac/config"

HOME_DIR=$(make_home)
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --backend invalid >/tmp/memory-cache-install-bad-backend.out 2>&1; then
  fail "invalid backend unexpectedly succeeded"
fi
grep -Fq "Unsupported backend" /tmp/memory-cache-install-bad-backend.out || fail "missing invalid backend error"

HOME_DIR=$(make_home)
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --backend apfs --size banana >/tmp/memory-cache-install-bad-size.out 2>&1; then
  fail "invalid size unexpectedly succeeded"
fi
grep -Fq "Unsupported cache size" /tmp/memory-cache-install-bad-size.out || fail "missing invalid size error"

echo "install tests passed"
