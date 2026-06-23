#!/bin/sh

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
TMPFS_SCRIPT="$ROOT/src/create_tmpfs_cache.sh"
APFS_SCRIPT="$ROOT/src/create_apfs_cache.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_not_contains() {
  file=$1
  unexpected=$2
  if grep -Fq "$unexpected" "$file"; then
    fail "unexpected '$unexpected' in $file"
  fi
}

make_home() {
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-runtime.XXXXXX")
  mkdir -p "$tmp/home"
  printf '%s\n' "$tmp/home"
}

make_tmpfs_runtime() {
  dest=$1
  cache_size=$2
  target_user=$3
  target_home=$4
  {
    sed -n '1p' "$TMPFS_SCRIPT"
    printf '\n'
    printf '%s\n' "MEMORY_CACHE_INSTALLED='1'"
    printf '%s\n' "CACHE_SIZE='$cache_size'"
    printf '%s\n' "TARGET_USER='$target_user'"
    printf '%s\n' "TARGET_HOME='$target_home'"
    printf '\n'
    sed '1d;/^MEMORY_CACHE_INSTALLED=0$/d' "$TMPFS_SCRIPT"
  } > "$dest"
  chmod 755 "$dest"
}

make_apfs_runtime() {
  dest=$1
  cache_size=$2
  {
    sed -n '1p' "$APFS_SCRIPT"
    printf '\n'
    printf '%s\n' "MEMORY_CACHE_INSTALLED='1'"
    printf '%s\n' "CACHE_SIZE='$cache_size'"
    printf '\n'
    sed '1d;/^MEMORY_CACHE_INSTALLED=0$/d' "$APFS_SCRIPT"
  } > "$dest"
  chmod 755 "$dest"
}

assert_not_contains "$TMPFS_SCRIPT" "hdiutil"
assert_not_contains "$TMPFS_SCRIPT" "diskutil"
assert_not_contains "$TMPFS_SCRIPT" "APFS_MOUNT_PATH"
assert_not_contains "$APFS_SCRIPT" "mount_tmpfs"
assert_not_contains "$APFS_SCRIPT" "TMPFS_MOUNT_PATH"
assert_not_contains "$APFS_SCRIPT" "TARGET_HOME"
assert_not_contains "$APFS_SCRIPT" "TARGET_USER"

HOME_DIR=$(make_home)
if CACHE_SIZE=1g TARGET_USER=saber TARGET_HOME="$HOME_DIR" HOME="$HOME_DIR" "$TMPFS_SCRIPT" >/tmp/memory-cache-runtime-tmpfs-source.out 2>&1; then
  fail "source tmpfs runtime unexpectedly succeeded"
fi
grep -Fq "Missing installed constant: MEMORY_CACHE_INSTALLED" /tmp/memory-cache-runtime-tmpfs-source.out || fail "tmpfs source marker error not found"

HOME_DIR=$(make_home)
if CACHE_SIZE=1g HOME="$HOME_DIR" "$APFS_SCRIPT" >/tmp/memory-cache-runtime-apfs-source.out 2>&1; then
  fail "source apfs runtime unexpectedly succeeded"
fi
grep -Fq "Missing installed constant: MEMORY_CACHE_INSTALLED" /tmp/memory-cache-runtime-apfs-source.out || fail "apfs source marker error not found"

HOME_DIR=$(make_home)
mkdir -p "$HOME_DIR/tmpfs"
echo "keep me" > "$HOME_DIR/tmpfs/existing.txt"
RUNTIME="$HOME_DIR/create_tmpfs_cache.sh"
make_tmpfs_runtime "$RUNTIME" 1g saber "$HOME_DIR"
if HOME="$HOME_DIR" "$RUNTIME" >/tmp/memory-cache-runtime-nonempty.out 2>&1; then
  fail "non-empty ordinary tmpfs path unexpectedly succeeded"
fi
grep -Fq "Refusing to mount over non-empty directory" /tmp/memory-cache-runtime-nonempty.out || fail "non-empty directory error not found"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_tmpfs_cache.sh"
make_tmpfs_runtime "$RUNTIME" 1g saber "$HOME_DIR"
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
RUNTIME="$HOME_DIR/create_tmpfs_cache.sh"
make_tmpfs_runtime "$RUNTIME" 1g saber "$HOME_DIR"
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
RUNTIME="$HOME_DIR/create_apfs_cache.sh"
make_apfs_runtime "$RUNTIME" 1g
STUB_DIR="$HOME_DIR/bin-stubs-apfs-missing-mount"
mkdir -p "$STUB_DIR"
DETACH_LOG="$HOME_DIR/detach.log"
APFS_TEST_MOUNT_PATH="$HOME_DIR/apfs-mount"

cat > "$STUB_DIR/hdiutil" <<EOF_STUB
#!/bin/sh
if [ "\$1" = "attach" ]; then
  echo "/dev/disk9"
  exit 0
fi
if [ "\$1" = "detach" ]; then
  printf '%s\n' "\$*" >> "$DETACH_LOG"
  exit 0
fi
echo "unexpected hdiutil args: \$*" >&2
exit 1
EOF_STUB
chmod 755 "$STUB_DIR/hdiutil"

cat > "$STUB_DIR/diskutil" <<'EOF_STUB'
#!/bin/sh
exit 0
EOF_STUB
chmod 755 "$STUB_DIR/diskutil"

cat > "$STUB_DIR/mount" <<'EOF_STUB'
#!/bin/sh
echo "/dev/disk0s1 on /"
EOF_STUB
chmod 755 "$STUB_DIR/mount"

if HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_COMMANDS=1 \
  MEMORY_CACHE_TEST_APFS_MOUNT_PATH="$APFS_TEST_MOUNT_PATH" \
  HDIUTIL_CMD="$STUB_DIR/hdiutil" \
  DISKUTIL_CMD="$STUB_DIR/diskutil" \
  MOUNT_CMD="$STUB_DIR/mount" \
  "$RUNTIME" >/tmp/memory-cache-runtime-apfs-missing-mount.out 2>&1; then
  fail "apfs mountpoint-missing scenario unexpectedly succeeded"
fi
grep -Fq "APFS volume was not mounted at $APFS_TEST_MOUNT_PATH" /tmp/memory-cache-runtime-apfs-missing-mount.out || fail "missing APFS mount failure error"
grep -Fq "detach /dev/disk9" "$DETACH_LOG" || fail "APFS failure did not detach ramdisk"

HOME_DIR=$(make_home)
RUNTIME="$HOME_DIR/create_apfs_cache.sh"
make_apfs_runtime "$RUNTIME" 1g
STUB_DIR="$HOME_DIR/bin-stubs-apfs-hook-guard"
mkdir -p "$STUB_DIR"
APFS_TEST_MOUNT_PATH="$HOME_DIR/should-not-be-used"

cat > "$STUB_DIR/hdiutil" <<EOF_STUB
#!/bin/sh
if [ "\$1" = "attach" ]; then
  echo "/dev/disk10"
  exit 0
fi
if [ "\$1" = "detach" ]; then
  printf '%s\n' "\$*" >> "$DETACH_LOG"
  exit 0
fi
echo "unexpected hdiutil args: \$*" >&2
exit 1
EOF_STUB
chmod 755 "$STUB_DIR/hdiutil"

cat > "$STUB_DIR/diskutil" <<'EOF_STUB'
#!/bin/sh
exit 0
EOF_STUB
chmod 755 "$STUB_DIR/diskutil"

cat > "$STUB_DIR/mount" <<EOF_STUB
#!/bin/sh
echo "/dev/disk9s1 on $APFS_TEST_MOUNT_PATH (apfs, local)"
EOF_STUB
chmod 755 "$STUB_DIR/mount"

if HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_COMMANDS=1 \
  MEMORY_CACHE_TEST_APFS_MOUNT_PATH="$APFS_TEST_MOUNT_PATH" \
  HDIUTIL_CMD="$STUB_DIR/hdiutil" \
  DISKUTIL_CMD="$STUB_DIR/diskutil" \
  MOUNT_CMD="$STUB_DIR/mount" \
  "$RUNTIME" >/tmp/memory-cache-runtime-apfs-hook-enabled.out 2>&1; then
  :
else
  fail "apfs mountpoint override in test mode unexpectedly failed"
fi

grep -Fq 'if [ "${MEMORY_CACHE_TEST_COMMANDS:-0}" = "1" ] && [ -n "${MEMORY_CACHE_TEST_APFS_MOUNT_PATH:-}" ]; then' "$APFS_SCRIPT" || fail "APFS mount path hook lost its test-mode guard"
grep -Fq 'APFS_MOUNT_PATH=$MEMORY_CACHE_TEST_APFS_MOUNT_PATH' "$APFS_SCRIPT" || fail "APFS mount path hook assignment missing"

echo "runtime tests passed"
