#!/bin/sh

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/src/create_memory_cache.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_home() {
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-runtime.XXXXXX")
  mkdir -p "$tmp/home"
  printf '%s\n' "$tmp/home"
}

make_runtime_script() {
  dest=$1
  backend=$2
  service_mode=$3
  cache_size=$4
  target_user=$5
  target_home=$6

  {
    sed -n '1p' "$SCRIPT"
    printf '%s\n' "BACKEND='$backend'"
    printf '%s\n' "SERVICE_MODE='$service_mode'"
    printf '%s\n' "CACHE_SIZE='$cache_size'"
    printf '%s\n' "TARGET_USER='$target_user'"
    printf '%s\n' "TARGET_HOME='$target_home'"
    sed '1d' "$SCRIPT"
  } > "$dest"
  chmod 755 "$dest"
}

HOME_DIR=$(make_home)
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-missing-constants.out 2>&1; then
  fail "missing embedded constants unexpectedly succeeded"
fi
grep -Fq "Missing installed constant: BACKEND" /tmp/memory-cache-runtime-missing-constants.out || fail "missing constants error not found"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" other agent 1g saber "$HOME_DIR"
if HOME="$HOME_DIR" "$RUNTIME" >/tmp/memory-cache-runtime-bad-backend.out 2>&1; then
  fail "invalid backend unexpectedly succeeded"
fi
grep -Fq "Unsupported backend" /tmp/memory-cache-runtime-bad-backend.out || fail "invalid backend error not found"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" tmpfs '' 1g saber "$HOME_DIR"
if HOME="$HOME_DIR" "$RUNTIME" >/tmp/memory-cache-runtime-missing-service-mode.out 2>&1; then
  fail "missing SERVICE_MODE unexpectedly succeeded"
fi
grep -Fq "Missing installed constant: SERVICE_MODE" /tmp/memory-cache-runtime-missing-service-mode.out || fail "missing SERVICE_MODE error not found"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" tmpfs agent 1g '' "$HOME_DIR"
if HOME="$HOME_DIR" "$RUNTIME" >/tmp/memory-cache-runtime-missing-target-user.out 2>&1; then
  fail "missing TARGET_USER unexpectedly succeeded"
fi
grep -Fq "Missing installed constant: TARGET_USER" /tmp/memory-cache-runtime-missing-target-user.out || fail "missing TARGET_USER error not found"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" tmpfs agent 1g saber ''
if HOME="$HOME_DIR" "$RUNTIME" >/tmp/memory-cache-runtime-missing-target-home.out 2>&1; then
  fail "missing TARGET_HOME unexpectedly succeeded"
fi
grep -Fq "Missing installed constant: TARGET_HOME" /tmp/memory-cache-runtime-missing-target-home.out || fail "missing TARGET_HOME error not found"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" apfs agent 1g saber "$HOME_DIR"
HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" apfs agent bad saber "$HOME_DIR"

STUB_DIR="$HOME_DIR/bin-stubs-no-switch"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/hdiutil" <<'EOF_STUB'
#!/bin/sh
touch "$0.invoked"
echo "unexpected hdiutil invocation in test" >&2
exit 1
EOF_STUB
chmod 755 "$STUB_DIR/hdiutil"

cat > "$STUB_DIR/diskutil" <<'EOF_STUB'
#!/bin/sh
touch "$0.invoked"
echo "unexpected diskutil invocation in test" >&2
exit 1
EOF_STUB
chmod 755 "$STUB_DIR/diskutil"

cat > "$STUB_DIR/mount" <<'EOF_STUB'
#!/bin/sh
touch "$0.invoked"
echo "unexpected mount invocation in test" >&2
exit 1
EOF_STUB
chmod 755 "$STUB_DIR/mount"

if HOME="$HOME_DIR" \
  HDIUTIL_CMD="$STUB_DIR/hdiutil" \
  DISKUTIL_CMD="$STUB_DIR/diskutil" \
  MOUNT_CMD="$STUB_DIR/mount" \
  "$RUNTIME" >/tmp/memory-cache-runtime-command-injection-unused.out 2>&1; then
  fail "runtime command injection override unexpectedly succeeded"
fi
grep -Fq "Unsupported cache size" /tmp/memory-cache-runtime-command-injection-unused.out || fail "invalid size error not found"
[ ! -f "$STUB_DIR/hdiutil.invoked" ] || fail "injected HDIUTIL_CMD was executed without MEMORY_CACHE_TEST_COMMANDS"
[ ! -f "$STUB_DIR/diskutil.invoked" ] || fail "injected DISKUTIL_CMD was executed without MEMORY_CACHE_TEST_COMMANDS"
[ ! -f "$STUB_DIR/mount.invoked" ] || fail "injected MOUNT_CMD was executed without MEMORY_CACHE_TEST_COMMANDS"

HOME_DIR=$(make_home)
mkdir -p "$HOME_DIR/tmpfs"
echo "keep me" > "$HOME_DIR/tmpfs/existing.txt"
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" tmpfs agent 1g saber "$HOME_DIR"
if HOME="$HOME_DIR" "$RUNTIME" >/tmp/memory-cache-runtime-nonempty.out 2>&1; then
  fail "non-empty ordinary tmpfs path unexpectedly succeeded"
fi
grep -Fq "Refusing to mount over non-empty directory" /tmp/memory-cache-runtime-nonempty.out || fail "non-empty directory error not found"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" tmpfs daemon 1g saber "$HOME_DIR"
CHOWN_LOG="$HOME_DIR/chown.log"
MOUNT_LOG="$HOME_DIR/mount.log"

STUB_DIR="$HOME_DIR/bin-stubs-chown"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/mount_tmpfs" <<EOF_STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$MOUNT_LOG"
exit 0
EOF_STUB
chmod 755 "$STUB_DIR/mount_tmpfs"

cat > "$STUB_DIR/chown" <<EOF_STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$CHOWN_LOG"
exit 0
EOF_STUB
chmod 755 "$STUB_DIR/chown"

cat > "$STUB_DIR/mount" <<'EOF_STUB'
#!/bin/sh
echo "/dev/disk0s1 on /"
EOF_STUB
chmod 755 "$STUB_DIR/mount"

if ! HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_COMMANDS=1 \
  MOUNT_TMPFS_CMD="$STUB_DIR/mount_tmpfs" \
  CHOWN_CMD="$STUB_DIR/chown" \
  MOUNT_CMD="$STUB_DIR/mount" \
  "$RUNTIME" >/tmp/memory-cache-runtime-chown-after-mount.out 2>&1; then
  fail "tmpfs mount with chown unexpectedly failed"
fi
[ -d "$HOME_DIR/tmpfs/Downloads" ] || fail "Downloads dir missing after tmpfs mount"
[ -d "$HOME_DIR/tmpfs/Cache/Chrome" ] || fail "Cache/Chrome dir missing after tmpfs mount"
[ -d "$HOME_DIR/tmpfs/Cache/Music" ] || fail "Cache/Music dir missing after tmpfs mount"
grep -Fq "saber $HOME_DIR/tmpfs" "$CHOWN_LOG" || fail "tmpfs root ownership was not fixed after mount"
grep -Fq "saber $HOME_DIR/tmpfs/Downloads" "$CHOWN_LOG" || fail "Downloads ownership was not fixed after mount"
grep -Fq "saber $HOME_DIR/tmpfs/Cache/Chrome" "$CHOWN_LOG" || fail "Cache/Chrome ownership was not fixed after mount"
grep -Fq "saber $HOME_DIR/tmpfs/Cache/Music" "$CHOWN_LOG" || fail "Cache/Music ownership was not fixed after mount"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" tmpfs daemon 1g saber "$HOME_DIR"
CHOWN_LOG="$HOME_DIR/chown-mounted.log"

STUB_DIR="$HOME_DIR/bin-stubs-mounted"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/chown" <<EOF_STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$CHOWN_LOG"
exit 0
EOF_STUB
chmod 755 "$STUB_DIR/chown"

cat > "$STUB_DIR/mount" <<EOF_STUB
#!/bin/sh
echo "tmpfs on $HOME_DIR/tmpfs (tmpfs, local)"
EOF_STUB
chmod 755 "$STUB_DIR/mount"

if ! HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_COMMANDS=1 \
  CHOWN_CMD="$STUB_DIR/chown" \
  MOUNT_CMD="$STUB_DIR/mount" \
  "$RUNTIME" >/tmp/memory-cache-runtime-chown-mounted.out 2>&1; then
  fail "already-mounted tmpfs ownership fix unexpectedly failed"
fi
[ -d "$HOME_DIR/tmpfs/Downloads" ] || fail "Downloads dir missing for already-mounted tmpfs"
[ -d "$HOME_DIR/tmpfs/Cache/Chrome" ] || fail "Cache/Chrome dir missing for already-mounted tmpfs"
[ -d "$HOME_DIR/tmpfs/Cache/Music" ] || fail "Cache/Music dir missing for already-mounted tmpfs"
grep -Fq "saber $HOME_DIR/tmpfs" "$CHOWN_LOG" || fail "tmpfs root ownership was not fixed for already-mounted tmpfs"
grep -Fq "saber $HOME_DIR/tmpfs/Downloads" "$CHOWN_LOG" || fail "Downloads ownership was not fixed for already-mounted tmpfs"
grep -Fq "saber $HOME_DIR/tmpfs/Cache/Chrome" "$CHOWN_LOG" || fail "Cache/Chrome ownership was not fixed for already-mounted tmpfs"
grep -Fq "saber $HOME_DIR/tmpfs/Cache/Music" "$CHOWN_LOG" || fail "Cache/Music ownership was not fixed for already-mounted tmpfs"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" tmpfs invalid 1g saber "$HOME_DIR"
if HOME="$HOME_DIR" "$RUNTIME" >/tmp/memory-cache-runtime-bad-service-mode.out 2>&1; then
  fail "invalid service mode unexpectedly succeeded"
fi
grep -Fq "Unsupported service mode" /tmp/memory-cache-runtime-bad-service-mode.out || fail "invalid service mode error not found"

echo "runtime tests passed"
