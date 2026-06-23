#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.memory-cache"
OLD_LABEL="com.local.ramdisk"
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/src/create_memory_cache.sh"
AGENT_PLIST_TEMPLATE="$SCRIPT_DIR/src/$LABEL.agent.plist.template"
DAEMON_PLIST_TEMPLATE="$SCRIPT_DIR/src/$LABEL.daemon.plist.template"
SKIP_LAUNCHCTL="${MEMORY_CACHE_SKIP_LAUNCHCTL:-0}"

BACKEND_ARG=""
SIZE_ARG=""

SERVICE_MODE=""
TARGET_USER=""
TARGET_HOME=""
TARGET_UID=""
SYSTEM_ROOT=""
INSTALL_SCRIPT=""
PLIST_PATH=""
PLIST_TEMPLATE=""
CONFIG_DIR=""
CONFIG_PATH=""
LOG_DIR=""
LOG_PATH=""
ERR_LOG_PATH=""
OLD_SCRIPT=""
OLD_PLIST=""

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

effective_uid() {
  if [ -n "${MEMORY_CACHE_TEST_EFFECTIVE_UID:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_EFFECTIVE_UID"
  else
    id -u
  fi
}

resolve_target_user() {
  if [ -n "${MEMORY_CACHE_TEST_TARGET_USER:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_TARGET_USER"
    return
  fi

  if [ "$(effective_uid)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      printf '%s\n' "$SUDO_USER"
      return
    fi
    return 1
  fi

  id -un
}

resolve_target_home() {
  if [ -n "${MEMORY_CACHE_TEST_TARGET_HOME:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_TARGET_HOME"
    return
  fi

  if [ "$(effective_uid)" -eq 0 ]; then
    dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    printf '%s\n' "$HOME"
  fi
}

resolve_system_root() {
  if [ -n "${MEMORY_CACHE_TEST_SYSTEM_ROOT:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_SYSTEM_ROOT"
  else
    printf '%s\n' "/"
  fi
}

service_mode_for_backend() {
  case "$1" in
    tmpfs) printf '%s\n' "daemon" ;;
    apfs) printf '%s\n' "agent" ;;
    *) return 1 ;;
  esac
}

set_paths_for_mode() {
  service_mode=$1

  case "$service_mode" in
    agent)
      INSTALL_SCRIPT="$TARGET_HOME/.local/bin/create_memory_cache.sh"
      PLIST_PATH="$TARGET_HOME/Library/LaunchAgents/$LABEL.plist"
      PLIST_TEMPLATE="$AGENT_PLIST_TEMPLATE"
      CONFIG_DIR="$TARGET_HOME/.config/memory-cache-for-mac"
      CONFIG_PATH="$CONFIG_DIR/config"
      LOG_DIR="$TARGET_HOME/Library/Logs"
      LOG_PATH="$LOG_DIR/memory-cache.log"
      ERR_LOG_PATH="$LOG_DIR/memory-cache.err.log"
      OLD_SCRIPT="$TARGET_HOME/.local/bin/create_ram_disk.sh"
      OLD_PLIST="$TARGET_HOME/Library/LaunchAgents/$OLD_LABEL.plist"
      ;;
    daemon)
      INSTALL_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
      PLIST_PATH="$SYSTEM_ROOT/Library/LaunchDaemons/$LABEL.plist"
      PLIST_TEMPLATE="$DAEMON_PLIST_TEMPLATE"
      CONFIG_DIR="$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac"
      CONFIG_PATH="$CONFIG_DIR/config"
      LOG_DIR="$SYSTEM_ROOT/Library/Logs"
      LOG_PATH="$LOG_DIR/memory-cache.log"
      ERR_LOG_PATH="$LOG_DIR/memory-cache.err.log"
      OLD_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
      OLD_PLIST="$SYSTEM_ROOT/Library/LaunchDaemons/$OLD_LABEL.plist"
      ;;
    *)
      echo "Unsupported service mode: $service_mode" >&2
      exit 1
      ;;
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

ensure_backend_prerequisites() {
  backend=$1

  if [ "$backend" = "tmpfs" ] && ! has_tmpfs; then
    echo "tmpfs backend requires mount_tmpfs" >&2
    exit 1
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

remove_files_if_present() {
  rm -f "$@"
}

bootout_agent_if_present() {
  agent_plist="$TARGET_HOME/Library/LaunchAgents/$LABEL.plist"
  if [ "$SKIP_LAUNCHCTL" != "1" ]; then
    launchctl bootout "gui/$(id -u "$TARGET_USER" 2>/dev/null || effective_uid)" "$agent_plist" >/dev/null 2>&1 || true
  fi
}

bootout_daemon_if_present() {
  daemon_plist="$SYSTEM_ROOT/Library/LaunchDaemons/$LABEL.plist"
  if [ "$SKIP_LAUNCHCTL" != "1" ]; then
    launchctl bootout system "$daemon_plist" >/dev/null 2>&1 || true
  fi
}

cleanup_current_mode_legacy() {
  if [ "$SERVICE_MODE" = "agent" ]; then
    if [ "$SKIP_LAUNCHCTL" != "1" ]; then
      launchctl bootout "gui/$TARGET_UID" "$OLD_PLIST" >/dev/null 2>&1 || true
    fi
  else
    if [ "$SKIP_LAUNCHCTL" != "1" ]; then
      launchctl bootout system "$OLD_PLIST" >/dev/null 2>&1 || true
    fi
  fi

  remove_files_if_present "$OLD_PLIST" "$OLD_SCRIPT"
}

cleanup_opposite_mode() {
  case "$SERVICE_MODE" in
    agent)
      bootout_daemon_if_present
      remove_files_if_present \
        "$SYSTEM_ROOT/Library/LaunchDaemons/$LABEL.plist" \
        "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh" \
        "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config" \
        "$SYSTEM_ROOT/Library/Logs/memory-cache.log" \
        "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log" \
        "$SYSTEM_ROOT/Library/LaunchDaemons/$OLD_LABEL.plist" \
        "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
      ;;
    daemon)
      bootout_agent_if_present
      remove_files_if_present \
        "$TARGET_HOME/Library/LaunchAgents/$LABEL.plist" \
        "$TARGET_HOME/.local/bin/create_memory_cache.sh" \
        "$TARGET_HOME/.config/memory-cache-for-mac/config" \
        "$TARGET_HOME/Library/Logs/memory-cache.log" \
        "$TARGET_HOME/Library/Logs/memory-cache.err.log" \
        "$TARGET_HOME/Library/LaunchAgents/$OLD_LABEL.plist" \
        "$TARGET_HOME/.local/bin/create_ram_disk.sh"
      ;;
  esac
}

validate_target_context() {
  if [ "$TARGET_USER" = "root" ]; then
    echo "Target user must not be root" >&2
    exit 1
  fi

  if [ -z "$TARGET_HOME" ]; then
    echo "Target home must not be empty" >&2
    exit 1
  fi

  if [ "$(effective_uid)" -eq 0 ]; then
    case "$TARGET_HOME" in
      /Users/*) ;;
      *)
        if [ -n "${MEMORY_CACHE_TEST_TARGET_HOME:-}" ]; then
          return
        fi
        echo "Target home must be under /Users: $TARGET_HOME" >&2
        exit 1
        ;;
    esac
  fi
}

write_config() {
  backend=$1
  cache_size=$2

  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_PATH" <<EOF_CONFIG
BACKEND=$backend
CACHE_SIZE=$cache_size
SERVICE_MODE=$SERVICE_MODE
TARGET_USER=$TARGET_USER
TARGET_HOME=$TARGET_HOME
TMPFS_MOUNT_PATH="$TARGET_HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
  chmod 644 "$CONFIG_PATH"
}

install_files() {
  [ -f "$SOURCE_SCRIPT" ] || { echo "Missing source script: $SOURCE_SCRIPT" >&2; exit 1; }
  [ -f "$PLIST_TEMPLATE" ] || { echo "Missing plist template: $PLIST_TEMPLATE" >&2; exit 1; }

  case "$SERVICE_MODE" in
    agent)
      mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/Library/LaunchAgents" "$LOG_DIR"
      cp "$SOURCE_SCRIPT" "$INSTALL_SCRIPT"
      chmod 755 "$INSTALL_SCRIPT"
      sed "s#__HOME__#$TARGET_HOME#g" "$PLIST_TEMPLATE" > "$PLIST_PATH"
      ;;
    daemon)
      mkdir -p "$(dirname "$INSTALL_SCRIPT")" "$(dirname "$PLIST_PATH")" "$LOG_DIR"
      cp "$SOURCE_SCRIPT" "$INSTALL_SCRIPT"
      chmod 755 "$INSTALL_SCRIPT"
      cp "$PLIST_TEMPLATE" "$PLIST_PATH"
      ;;
  esac

  chmod 644 "$PLIST_PATH"
}

load_service() {
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi

  case "$SERVICE_MODE" in
    agent)
      user_uid=$(id -u "$TARGET_USER" 2>/dev/null || effective_uid)
      launchctl bootout "gui/$user_uid" "$PLIST_PATH" >/dev/null 2>&1 || true
      if ! launchctl bootstrap "gui/$user_uid" "$PLIST_PATH" 2>/dev/null; then
        if [ "$(effective_uid)" -eq 0 ]; then
          echo "launchctl bootstrap failed for gui/$user_uid" >&2
          exit 1
        fi
        echo "launchctl bootstrap failed for gui/$user_uid; retrying with sudo..." >&2
        sudo launchctl bootstrap "gui/$user_uid" "$PLIST_PATH"
      fi
      launchctl kickstart -k "gui/$user_uid/$LABEL" >/dev/null 2>&1 || true
      ;;
    daemon)
      launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
      launchctl bootstrap system "$PLIST_PATH"
      launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
      ;;
  esac
}

parse_args "$@"
recommended_backend=$(recommend_backend)
recommended_size=$(recommend_size)
backend=$(choose_backend "$recommended_backend")
SERVICE_MODE=$(service_mode_for_backend "$backend")

if [ "$SERVICE_MODE" = "daemon" ] && [ "$(effective_uid)" -ne 0 ]; then
  echo "tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root" >&2
  exit 1
fi

cache_size=$(choose_size "$recommended_size")
ensure_backend_prerequisites "$backend"
SYSTEM_ROOT=$(resolve_system_root)

TARGET_USER=$(resolve_target_user) || {
  echo "Could not determine target user; rerun with sudo from a user session or set SUDO_USER" >&2
  exit 1
}
TARGET_HOME=$(resolve_target_home "$TARGET_USER")
[ -n "$TARGET_HOME" ] || { echo "Could not resolve target home for $TARGET_USER" >&2; exit 1; }
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || effective_uid)
validate_target_context

set_paths_for_mode "$SERVICE_MODE"
cleanup_opposite_mode
cleanup_current_mode_legacy
install_files
write_config "$backend" "$cache_size"
load_service

echo "Installed $LABEL"
echo "Backend: $backend"
echo "Cache size: $cache_size"
echo "Service mode: $SERVICE_MODE"
echo "Target user: $TARGET_USER"
echo "Target home: $TARGET_HOME"
echo "Config: $CONFIG_PATH"
echo "Script: $INSTALL_SCRIPT"
echo "Plist: $PLIST_PATH"
echo "Logs: $LOG_PATH and $ERR_LOG_PATH"
