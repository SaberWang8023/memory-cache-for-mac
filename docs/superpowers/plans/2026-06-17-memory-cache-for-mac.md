# memory-cache-for-mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the project from `ramdisk-for-mac` to `memory-cache-for-mac`, add a default `tmpfs` backend with APFS ramdisk as an option, and make installation configurable and testable.

**Architecture:** Keep the project as a small POSIX `sh` toolset. `install.sh` owns user choices, config generation, LaunchAgent installation, and old-asset migration; `src/create_memory_cache.sh` owns runtime mounting and directory creation; `uninstall.sh` removes installed assets without unmounting cache roots.

**Tech Stack:** POSIX `sh`, macOS `launchctl`, `mount_tmpfs`, `hdiutil`, `diskutil`, `sysctl`, shell-based tests under `tests/`.

## Global Constraints

- Responding implementation must keep shell scripts compatible with `/bin/sh`.
- The project name becomes `memory-cache-for-mac`.
- Supported backends are `tmpfs` and `apfs`.
- If `mount_tmpfs` is available, installation recommends `tmpfs`; users may still choose `apfs`.
- If `mount_tmpfs` is unavailable, installation recommends `apfs`.
- Runtime must respect configured `BACKEND` and must not silently fall back to another backend or a regular directory.
- `tmpfs` mount path defaults to `~/tmpfs`.
- APFS mount path defaults to `/Volumes/Ramdisk`.
- Default child directories are `Downloads`, `Cache/Chrome`, and `Cache/Music`.
- Capacity recommendation is based on physical memory: `<= 16 GB` recommends `512m`; `> 16 GB` and `<= 48 GB` recommends `1g`; `> 48 GB` recommends `2g`.
- Users can override capacity during install or later by editing `CACHE_SIZE`.
- `CACHE_SIZE` must support at least `m` and `g` suffixes such as `512m`, `1g`, and `2g`.
- Installer must use `sysctl -n hw.memsize` for memory detection, with `512m` fallback if detection fails.
- Installed files are `~/.local/bin/create_memory_cache.sh`, `~/Library/LaunchAgents/com.local.memory-cache.plist`, `~/Library/Logs/memory-cache.log`, `~/Library/Logs/memory-cache.err.log`, and `~/.config/memory-cache-for-mac/config`.
- Installer must stop and remove old `com.local.ramdisk` launch assets and `~/.local/bin/create_ram_disk.sh`.
- Installer and uninstaller must not automatically unmount `~/tmpfs` or `/Volumes/Ramdisk`.
- Uninstaller must not delete the `~/tmpfs` directory itself.

---

## File Structure

- Create `src/create_memory_cache.sh`: runtime script that reads config, validates values, mounts `tmpfs` or APFS ramdisk, and creates child directories.
- Create `src/com.local.memory-cache.plist.template`: LaunchAgent template pointing at `create_memory_cache.sh` and memory-cache logs.
- Remove `src/create_ram_disk.sh` after its APFS logic has been ported into `src/create_memory_cache.sh`.
- Remove `src/com.local.ramdisk.plist.template` after the new template is created.
- Modify `install.sh`: parse `--backend` and `--size`, choose recommended backend and capacity, write config, install renamed files, clean old installed assets, and support test mode with `MEMORY_CACHE_SKIP_LAUNCHCTL=1`.
- Modify `uninstall.sh`: remove renamed installed files and config, clean old installed assets, skip mount removal, and support `MEMORY_CACHE_SKIP_LAUNCHCTL=1`.
- Modify `README.md` and `README.zh-CN.md`: document new project name, backend choices, capacity recommendation, install options, use cases, migration, and manual cleanup.
- Create `tests/install_test.sh`: verifies installer config generation and argument validation using a temporary `HOME`.
- Create `tests/runtime_test.sh`: verifies runtime validation and safe refusal to mount over a non-empty ordinary directory without needing a real mount.
- Create `tests/uninstall_test.sh`: verifies uninstall removes installed assets and keeps mount roots.

### Task 1: Installer, Config, And LaunchAgent Rename

**Files:**
- Modify: `install.sh`
- Create: `tests/install_test.sh`
- Create: `src/create_memory_cache.sh`
- Create: `src/com.local.memory-cache.plist.template`
- Delete: `src/create_ram_disk.sh`
- Delete: `src/com.local.ramdisk.plist.template`

**Interfaces:**
- Produces installed config at `$HOME/.config/memory-cache-for-mac/config`.
- Produces installed runtime script at `$HOME/.local/bin/create_memory_cache.sh`.
- Produces installed plist at `$HOME/Library/LaunchAgents/com.local.memory-cache.plist`.
- Provides installer arguments `--backend tmpfs|apfs` and `--size <number>[mMgG]`.
- Provides test controls `MEMORY_CACHE_SKIP_LAUNCHCTL=1` and `MEMORY_CACHE_TEST_MEMSIZE_BYTES=<bytes>`.

- [ ] **Step 1: Write failing installer tests**

Create `tests/install_test.sh`:

```sh
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
```

- [ ] **Step 2: Run installer tests and verify they fail before implementation**

Run:

```sh
sh tests/install_test.sh
```

Expected: failure because `install.sh` does not yet understand `--backend`, `--size`, or the renamed files.

- [ ] **Step 3: Create the new LaunchAgent template**

Create `src/com.local.memory-cache.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.local.memory-cache</string>
	<key>Program</key>
	<string>__HOME__/.local/bin/create_memory_cache.sh</string>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>__HOME__/Library/Logs/memory-cache.log</string>
	<key>StandardErrorPath</key>
	<string>__HOME__/Library/Logs/memory-cache.err.log</string>
</dict>
</plist>
```

- [ ] **Step 4: Create a temporary runtime script stub**

Create `src/create_memory_cache.sh` with a minimal executable stub so the installer can copy it; Task 2 replaces it with real runtime behavior:

```sh
#!/bin/sh

set -eu

echo "Missing config: $HOME/.config/memory-cache-for-mac/config. Re-run ./install.sh." >&2
exit 1
```

- [ ] **Step 5: Replace `install.sh` with the new installer**

Implement `install.sh` with these functions and behavior:

```sh
#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.memory-cache"
OLD_LABEL="com.local.ramdisk"
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/src/create_memory_cache.sh"
PLIST_TEMPLATE="$SCRIPT_DIR/src/$LABEL.plist.template"
INSTALL_SCRIPT="$HOME/.local/bin/create_memory_cache.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/memory-cache-for-mac"
CONFIG_PATH="$CONFIG_DIR/config"
LOG_DIR="$HOME/Library/Logs"
OLD_SCRIPT="$HOME/.local/bin/create_ram_disk.sh"
OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
SKIP_LAUNCHCTL="${MEMORY_CACHE_SKIP_LAUNCHCTL:-0}"

BACKEND_ARG=""
SIZE_ARG=""

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--backend tmpfs|apfs] [--size 512m|1g|2g]
USAGE
}

has_tmpfs() {
  command -v mount_tmpfs >/dev/null 2>&1
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

recommend_size() {
  mem_bytes=${MEMORY_CACHE_TEST_MEMSIZE_BYTES:-}
  if [ -z "$mem_bytes" ]; then
    mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
  fi

  case "$mem_bytes" in
    ''|*[!0-9]*) printf '%s\n' "512m"; return ;;
  esac

  mem_gb=$(awk -v bytes="$mem_bytes" 'BEGIN { printf "%d", (bytes + 1073741823) / 1073741824 }')
  if [ "$mem_gb" -le 16 ]; then
    printf '%s\n' "512m"
  elif [ "$mem_gb" -le 48 ]; then
    printf '%s\n' "1g"
  else
    printf '%s\n' "2g"
  fi
}

recommend_backend() {
  if has_tmpfs; then
    printf '%s\n' "tmpfs"
  else
    printf '%s\n' "apfs"
  fi
}

validate_backend() {
  case "$1" in
    tmpfs|apfs) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --backend)
        [ "$#" -ge 2 ] || { echo "Missing value for --backend" >&2; exit 1; }
        BACKEND_ARG=$2
        shift 2
        ;;
      --size)
        [ "$#" -ge 2 ] || { echo "Missing value for --size" >&2; exit 1; }
        SIZE_ARG=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

choose_backend() {
  recommended=$1
  if [ -n "$BACKEND_ARG" ]; then
    validate_backend "$BACKEND_ARG" || { echo "Unsupported backend: $BACKEND_ARG" >&2; exit 1; }
    [ "$BACKEND_ARG" = "tmpfs" ] && ! has_tmpfs && { echo "tmpfs backend requires mount_tmpfs" >&2; exit 1; }
    printf '%s\n' "$BACKEND_ARG"
    return
  fi

  if [ -t 0 ]; then
    echo "Choose backend:" >&2
    if [ "$recommended" = "tmpfs" ]; then
      echo "  1) tmpfs (recommended): directory-style volatile cache at ~/tmpfs" >&2
      echo "  2) APFS ramdisk: volume-style cache at /Volumes/Ramdisk" >&2
      printf "Press Enter for tmpfs, or type 2 for APFS ramdisk: " >&2
      read answer
      case "$answer" in
        ''|1) printf '%s\n' "tmpfs" ;;
        2) printf '%s\n' "apfs" ;;
        *) echo "Unsupported selection: $answer" >&2; exit 1 ;;
      esac
    else
      echo "  1) APFS ramdisk (recommended): volume-style cache at /Volumes/Ramdisk" >&2
      printf "Press Enter for APFS ramdisk: " >&2
      read answer
      case "$answer" in
        ''|1) printf '%s\n' "apfs" ;;
        *) echo "Unsupported selection: $answer" >&2; exit 1 ;;
      esac
    fi
  else
    printf '%s\n' "$recommended"
  fi
}

choose_size() {
  recommended=$1
  if [ -n "$SIZE_ARG" ]; then
    normalize_size "$SIZE_ARG" || { echo "Unsupported cache size: $SIZE_ARG" >&2; exit 1; }
    return
  fi

  if [ -t 0 ]; then
    printf "Cache size [%s]: " "$recommended" >&2
    read answer
    if [ -z "$answer" ]; then
      printf '%s\n' "$recommended"
    else
      normalize_size "$answer" || { echo "Unsupported cache size: $answer" >&2; exit 1; }
    fi
  else
    printf '%s\n' "$recommended"
  fi
}

cleanup_old_install() {
  if [ "$SKIP_LAUNCHCTL" != "1" ]; then
    launchctl bootout "gui/$(id -u)" "$OLD_PLIST" >/dev/null 2>&1 || true
  fi
  rm -f "$OLD_PLIST" "$OLD_SCRIPT"
}

write_config() {
  backend=$1
  cache_size=$2
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_PATH" <<EOF_CONFIG
BACKEND=$backend
CACHE_SIZE=$cache_size
TMPFS_MOUNT_PATH="\$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
  chmod 644 "$CONFIG_PATH"
}

install_files() {
  [ -f "$SOURCE_SCRIPT" ] || { echo "Missing source script: $SOURCE_SCRIPT" >&2; exit 1; }
  [ -f "$PLIST_TEMPLATE" ] || { echo "Missing plist template: $PLIST_TEMPLATE" >&2; exit 1; }
  mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$LOG_DIR"
  cp "$SOURCE_SCRIPT" "$INSTALL_SCRIPT"
  chmod 755 "$INSTALL_SCRIPT"
  sed "s#__HOME__#$HOME#g" "$PLIST_TEMPLATE" > "$PLIST_PATH"
  chmod 644 "$PLIST_PATH"
}

load_launch_agent() {
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
    echo "launchctl bootstrap failed as the current user; retrying with sudo..."
    sudo launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  fi
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
}

parse_args "$@"
recommended_backend=$(recommend_backend)
recommended_size=$(recommend_size)
backend=$(choose_backend "$recommended_backend")
cache_size=$(choose_size "$recommended_size")

cleanup_old_install
install_files
write_config "$backend" "$cache_size"
load_launch_agent

echo "Installed $LABEL"
echo "Backend: $backend"
echo "Cache size: $cache_size"
echo "Config: $CONFIG_PATH"
echo "Script: $INSTALL_SCRIPT"
echo "LaunchAgent: $PLIST_PATH"
echo "Logs: $LOG_DIR/memory-cache.log and $LOG_DIR/memory-cache.err.log"
```

- [ ] **Step 6: Remove old source files**

Run:

```sh
rm src/create_ram_disk.sh src/com.local.ramdisk.plist.template
```

Expected: old source files are removed from the working tree after their behavior is represented by new files.

- [ ] **Step 7: Run installer tests**

Run:

```sh
sh tests/install_test.sh
```

Expected:

```text
install tests passed
```

- [ ] **Step 8: Commit installer task**

Run:

```sh
git add install.sh src/create_memory_cache.sh src/com.local.memory-cache.plist.template src/create_ram_disk.sh src/com.local.ramdisk.plist.template tests/install_test.sh
git commit -m "feat: add configurable memory-cache installer"
```

### Task 2: Runtime Backend Script

**Files:**
- Modify: `src/create_memory_cache.sh`
- Create: `tests/runtime_test.sh`

**Interfaces:**
- Consumes config file at `$HOME/.config/memory-cache-for-mac/config`.
- Consumes `BACKEND`, `CACHE_SIZE`, `TMPFS_MOUNT_PATH`, `APFS_DISK_NAME`, `APFS_MOUNT_PATH`, and `CREATE_DIRS`.
- Produces mounted cache root and child directories for the configured backend.
- Produces `MEMORY_CACHE_CONFIG_PATH` test override for runtime tests.

- [ ] **Step 1: Write failing runtime tests**

Create `tests/runtime_test.sh`:

```sh
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
```

- [ ] **Step 2: Run runtime tests and verify they fail before implementation**

Run:

```sh
sh tests/runtime_test.sh
```

Expected: failure because the runtime stub does not read config or validate inputs.

- [ ] **Step 3: Replace runtime script with backend implementation**

Replace `src/create_memory_cache.sh` with:

```sh
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
```

- [ ] **Step 4: Run runtime tests**

Run:

```sh
sh tests/runtime_test.sh
```

Expected:

```text
runtime tests passed
```

- [ ] **Step 5: Run syntax checks**

Run:

```sh
sh -n src/create_memory_cache.sh install.sh tests/install_test.sh tests/runtime_test.sh
```

Expected: no output and exit code 0.

- [ ] **Step 6: Commit runtime task**

Run:

```sh
git add src/create_memory_cache.sh tests/runtime_test.sh
git commit -m "feat: add tmpfs and apfs runtime backends"
```

### Task 3: Uninstall And Migration Cleanup

**Files:**
- Modify: `uninstall.sh`
- Create: `tests/uninstall_test.sh`

**Interfaces:**
- Consumes installed paths from the spec.
- Removes new and old installed scripts and plists.
- Removes `~/.config/memory-cache-for-mac/config`.
- Does not unmount or delete `~/tmpfs` or `/Volumes/Ramdisk`.
- Supports `MEMORY_CACHE_SKIP_LAUNCHCTL=1` for tests.

- [ ] **Step 1: Write failing uninstall tests**

Create `tests/uninstall_test.sh`:

```sh
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
mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Library/LaunchAgents" "$HOME_DIR/.config/memory-cache-for-mac" "$HOME_DIR/tmpfs"

: > "$HOME_DIR/.local/bin/create_memory_cache.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
: > "$HOME_DIR/.config/memory-cache-for-mac/config"
: > "$HOME_DIR/.local/bin/create_ram_disk.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
echo "keep" > "$HOME_DIR/tmpfs/keep.txt"

MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/uninstall.sh" >/tmp/memory-cache-uninstall.out

assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
assert_absent "$HOME_DIR/.config/memory-cache-for-mac/config"
assert_absent "$HOME_DIR/.local/bin/create_ram_disk.sh"
assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
assert_dir "$HOME_DIR/tmpfs"
[ -f "$HOME_DIR/tmpfs/keep.txt" ] || fail "tmpfs contents were removed"
grep -Fq "Manual cleanup" /tmp/memory-cache-uninstall.out || fail "missing manual cleanup hint"

echo "uninstall tests passed"
```

- [ ] **Step 2: Run uninstall tests and verify they fail before implementation**

Run:

```sh
sh tests/uninstall_test.sh
```

Expected: failure because `uninstall.sh` still removes only old ramdisk files and does not know new paths.

- [ ] **Step 3: Replace `uninstall.sh`**

Replace `uninstall.sh` with:

```sh
#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.memory-cache"
OLD_LABEL="com.local.ramdisk"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_SCRIPT="$HOME/.local/bin/create_memory_cache.sh"
CONFIG_PATH="$HOME/.config/memory-cache-for-mac/config"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
OLD_INSTALL_SCRIPT="$HOME/.local/bin/create_ram_disk.sh"
SKIP_LAUNCHCTL="${MEMORY_CACHE_SKIP_LAUNCHCTL:-0}"

bootout_if_needed() {
  label=$1
  plist=$2
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
}

bootout_if_needed "$LABEL" "$PLIST_PATH"
bootout_if_needed "$OLD_LABEL" "$OLD_PLIST_PATH"

rm -f "$PLIST_PATH" "$INSTALL_SCRIPT" "$CONFIG_PATH"
rm -f "$OLD_PLIST_PATH" "$OLD_INSTALL_SCRIPT"

echo "Uninstalled $LABEL"
echo "Manual cleanup, if desired:"
echo "  sudo umount ~/tmpfs"
echo "  diskutil eject /Volumes/Ramdisk"
echo "Mount roots are not unmounted or deleted automatically."
```

- [ ] **Step 4: Run uninstall tests and syntax checks**

Run:

```sh
sh tests/uninstall_test.sh
sh -n uninstall.sh tests/uninstall_test.sh
```

Expected:

```text
uninstall tests passed
```

The syntax check prints no output and exits 0.

- [ ] **Step 5: Commit uninstall task**

Run:

```sh
git add uninstall.sh tests/uninstall_test.sh
git commit -m "feat: update memory-cache uninstall"
```

### Task 4: Documentation And End-To-End Verification

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/superpowers/specs/2026-06-17-memory-cache-for-mac-design.md` only if implementation reveals a spec mismatch

**Interfaces:**
- Documents user commands `./install.sh`, `./install.sh --backend tmpfs`, `./install.sh --backend apfs`, `./install.sh --size 1g`, and `./install.sh --backend tmpfs --size 512m`.
- Documents config path `$HOME/.config/memory-cache-for-mac/config`.
- Documents manual cleanup commands `sudo umount ~/tmpfs` and `diskutil eject /Volumes/Ramdisk`.

- [ ] **Step 1: Update English README**

Replace `README.md` with content that includes these sections and examples:

```markdown
# memory-cache-for-mac

[中文说明](README.zh-CN.md)

A small macOS LaunchAgent setup that creates a volatile in-memory cache space at login.

It uses `tmpfs` by default when `mount_tmpfs` is available, and still supports an APFS ramdisk backend for users who want a real APFS volume.

## Use Cases

- temporary downloads
- Chrome cache
- music application cache
- build or scratch cache

Do not use this for files that must survive logout, reboot, unmounting, or installation changes.

## Backends

| Backend | Default path | Best for | Notes |
| --- | --- | --- | --- |
| `tmpfs` | `~/tmpfs` | disposable cache directories | default when `mount_tmpfs` is available |
| `apfs` | `/Volumes/Ramdisk` | users who want a volume-like APFS ramdisk | optional compatibility backend |

The runtime does not silently fall back between backends. If the configured backend fails, it exits with an error.

## Capacity

The installer recommends a cache size from physical memory:

| Physical memory | Recommended size |
| --- | --- |
| `<= 16 GB` | `512m` |
| `> 16 GB` and `<= 48 GB` | `1g` |
| `> 48 GB` | `2g` |

This is only a recommendation. You can choose another size during install or edit the config later.

## Install

Interactive install:

```sh
./install.sh
```

Non-interactive examples:

```sh
./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
./install.sh --backend tmpfs --size 512m
```

Installed files:

```text
~/.local/bin/create_memory_cache.sh
~/Library/LaunchAgents/com.local.memory-cache.plist
~/Library/Logs/memory-cache.log
~/Library/Logs/memory-cache.err.log
~/.config/memory-cache-for-mac/config
```

Default directories under the cache root:

```text
Downloads
Cache/Chrome
Cache/Music
```

## Configuration

Edit:

```text
~/.config/memory-cache-for-mac/config
```

Example:

```sh
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
```

## Migration From ramdisk-for-mac

Installing this version stops and removes the old `com.local.ramdisk` LaunchAgent and `~/.local/bin/create_ram_disk.sh`.

It does not eject an existing `/Volumes/Ramdisk` volume. If you want to remove it after checking its contents:

```sh
diskutil eject /Volumes/Ramdisk
```

## Uninstall

```sh
./uninstall.sh
```

Uninstall removes installed files and config, but does not unmount or delete cache roots. Manual cleanup:

```sh
sudo umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
```

- [ ] **Step 2: Update Chinese README**

Replace `README.zh-CN.md` with a faithful Chinese version of the English README:

```markdown
# memory-cache-for-mac

[English README](README.md)

一个小型 macOS LaunchAgent 配置，用于在登录时创建易失的内存缓存空间。

当 `mount_tmpfs` 可用时，它默认使用 `tmpfs`；同时仍支持 APFS ramdisk backend，供需要真实 APFS 卷的用户选择。

## 使用场景

- 临时下载
- Chrome 缓存
- 音乐应用缓存
- 构建缓存或临时 scratch 缓存

不要用它存放必须在注销、重启、卸载挂载点或安装变更后继续保留的文件。

## Backends

| Backend | 默认路径 | 适合场景 | 说明 |
| --- | --- | --- | --- |
| `tmpfs` | `~/tmpfs` | 可丢弃缓存目录 | `mount_tmpfs` 可用时默认选择 |
| `apfs` | `/Volumes/Ramdisk` | 需要卷语义的 APFS ramdisk 用户 | 可选兼容 backend |

运行脚本不会在 backend 之间静默回退。如果配置的 backend 失败，它会报错退出。

## 容量

安装器会根据物理内存推荐缓存容量：

| 物理内存 | 推荐容量 |
| --- | --- |
| `<= 16 GB` | `512m` |
| `> 16 GB` 且 `<= 48 GB` | `1g` |
| `> 48 GB` | `2g` |

这只是推荐值。你可以在安装时选择其他容量，也可以之后编辑配置。

## 安装

交互式安装：

```sh
./install.sh
```

非交互示例：

```sh
./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
./install.sh --backend tmpfs --size 512m
```

安装文件：

```text
~/.local/bin/create_memory_cache.sh
~/Library/LaunchAgents/com.local.memory-cache.plist
~/Library/Logs/memory-cache.log
~/Library/Logs/memory-cache.err.log
~/.config/memory-cache-for-mac/config
```

缓存根目录下默认创建：

```text
Downloads
Cache/Chrome
Cache/Music
```

## 配置

编辑：

```text
~/.config/memory-cache-for-mac/config
```

示例：

```sh
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
```

## 从 ramdisk-for-mac 迁移

安装这个版本会停止并移除旧的 `com.local.ramdisk` LaunchAgent 和 `~/.local/bin/create_ram_disk.sh`。

它不会弹出已有的 `/Volumes/Ramdisk` 卷。确认内容后，如需手动移除：

```sh
diskutil eject /Volumes/Ramdisk
```

## 卸载

```sh
./uninstall.sh
```

卸载会移除安装文件和配置，但不会卸载或删除缓存根目录。手动清理：

```sh
sudo umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
```

- [ ] **Step 3: Run the automated test suite**

Run:

```sh
sh tests/install_test.sh
sh tests/runtime_test.sh
sh tests/uninstall_test.sh
sh -n install.sh uninstall.sh src/create_memory_cache.sh tests/install_test.sh tests/runtime_test.sh tests/uninstall_test.sh
```

Expected:

```text
install tests passed
runtime tests passed
uninstall tests passed
```

The `sh -n` command prints no output and exits 0.

- [ ] **Step 4: Run manual tmpfs verification on a supported macOS system**

Run:

```sh
tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-manual.XXXXXX")/home
mkdir -p "$tmp_home"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$tmp_home" ./install.sh --backend tmpfs --size 512m
HOME="$tmp_home" "$tmp_home/.local/bin/create_memory_cache.sh"
mount | grep -F " on $tmp_home/tmpfs "
find "$tmp_home/tmpfs" -maxdepth 3 -type d | sort
umount "$tmp_home/tmpfs"
```

Expected directory output includes:

```text
Downloads
Cache
Cache/Chrome
Cache/Music
```

- [ ] **Step 5: Commit documentation and verification task**

Run:

```sh
git add README.md README.zh-CN.md tests install.sh uninstall.sh src
git commit -m "docs: document memory-cache backends"
```

## Self-Review

- Spec coverage: naming, backend selection, tmpfs default, APFS option, capacity recommendation, config path, installed files, migration, runtime failure behavior, uninstall conservatism, README updates, and tests are all mapped to tasks.
- Red-flag scan: checked common incomplete markers and cross-task shortcut phrasing; none remain.
- Interface consistency: installer writes `CACHE_SIZE`; runtime reads `CACHE_SIZE`; README and tests use the same variable and paths.
