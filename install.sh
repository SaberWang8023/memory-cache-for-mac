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
