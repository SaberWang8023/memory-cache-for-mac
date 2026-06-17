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

HOME_DIR=$(make_home)
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-missing.out 2>&1; then
  fail "missing config unexpectedly succeeded"
fi
grep -Fq "Missing config" /tmp/memory-cache-runtime-missing.out || fail "missing config error not found"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=other
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-bad-backend.out 2>&1; then
  fail "invalid backend unexpectedly succeeded"
fi
grep -Fq "Unsupported backend" /tmp/memory-cache-runtime-bad-backend.out || fail "invalid backend error not found"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH=
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-empty-tmpfs-path.out 2>&1; then
  fail "empty TMPFS_MOUNT_PATH unexpectedly succeeded"
fi
grep -Fq "Missing required config: TMPFS_MOUNT_PATH" /tmp/memory-cache-runtime-empty-tmpfs-path.out || fail "empty TMPFS_MOUNT_PATH error not found"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=tmpfs
CACHE_SIZE=1g
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
mkdir -p "$HOME_DIR/tmpfs"
echo "keep me" > "$HOME_DIR/tmpfs/existing.txt"
if HOME="$HOME_DIR" TMPFS_MOUNT_PATH="$HOME_DIR/tmpfs" "$SCRIPT" >/tmp/memory-cache-runtime-env-tmpfs-missing.out 2>&1; then
  fail "missing TMPFS_MOUNT_PATH with env fallback unexpectedly succeeded"
fi
grep -Fq "Missing required config: TMPFS_MOUNT_PATH" /tmp/memory-cache-runtime-env-tmpfs-missing.out || fail "missing TMPFS_MOUNT_PATH env fallback was ignored"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
EOF_CONFIG
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-missing-create-dirs.out 2>&1; then
  fail "missing CREATE_DIRS unexpectedly succeeded"
fi
grep -Fq "Missing required config: CREATE_DIRS" /tmp/memory-cache-runtime-missing-create-dirs.out || fail "missing CREATE_DIRS error not found"

HOME_DIR=$(make_home)
CONFIG_OVERRIDE="$HOME_DIR/override-config"
cat > "$CONFIG_OVERRIDE" <<EOF_CONFIG
BACKEND=other
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
if HOME="$HOME_DIR" MEMORY_CACHE_CONFIG_PATH="$CONFIG_OVERRIDE" "$SCRIPT" >/tmp/memory-cache-runtime-config-path-override.out 2>&1; then
  fail "MEMORY_CACHE_CONFIG_PATH override unexpectedly succeeded"
fi
grep -Fq "Unsupported backend" /tmp/memory-cache-runtime-config-path-override.out || fail "MEMORY_CACHE_CONFIG_PATH override was not used"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=apfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=FastRam
APFS_MOUNT_PATH="\$HOME/custom-apfs"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-apfs-custom-path.out 2>&1; then
  fail "custom APFS_MOUNT_PATH unexpectedly succeeded"
fi
grep -Fq "APFS_MOUNT_PATH must match /Volumes/FastRam for apfs backend" /tmp/memory-cache-runtime-apfs-custom-path.out || fail "custom APFS_MOUNT_PATH error not found"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=apfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG

STUB_DIR="$HOME_DIR/bin-stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/hdiutil" <<'EOF_STUB'
#!/bin/sh
if [ "$1" = "attach" ] && [ "$2" = "-nomount" ]; then
  echo "/dev/disk9"
  exit 0
fi
echo "unexpected hdiutil call: $*" >&2
exit 1
EOF_STUB
chmod 755 "$STUB_DIR/hdiutil"

cat > "$STUB_DIR/diskutil" <<'EOF_STUB'
#!/bin/sh
if [ "$1" = "partitionDisk" ]; then
  exit 0
fi
echo "unexpected diskutil call: $*" >&2
exit 1
EOF_STUB
chmod 755 "$STUB_DIR/diskutil"

cat > "$STUB_DIR/mount" <<'EOF_STUB'
#!/bin/sh
echo "/dev/disk0s1 on /"
echo "/dev/disk1s1 on /Applications"
EOF_STUB
chmod 755 "$STUB_DIR/mount"

if HOME="$HOME_DIR" PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" "$SCRIPT" >/tmp/memory-cache-runtime-apfs-not-mounted.out 2>&1; then
  fail "apfs mountpoint missing path unexpectedly succeeded"
fi
grep -Fq "APFS volume was not mounted at /Volumes/Ramdisk" /tmp/memory-cache-runtime-apfs-not-mounted.out || fail "apfs mountpoint error not found"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")" "$HOME_DIR/tmpfs"
echo "keep me" > "$HOME_DIR/tmpfs/existing.txt"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-nonempty.out 2>&1; then
  fail "non-empty ordinary tmpfs path unexpectedly succeeded"
fi
grep -Fq "Refusing to mount over non-empty directory" /tmp/memory-cache-runtime-nonempty.out || fail "non-empty directory error not found"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=tmpfs
CACHE_SIZE=bad
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-bad-size.out 2>&1; then
  fail "invalid cache size unexpectedly succeeded"
fi
grep -Fq "Unsupported cache size" /tmp/memory-cache-runtime-bad-size.out || fail "invalid size error not found"

echo "runtime tests passed"
