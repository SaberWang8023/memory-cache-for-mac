# 基于后端自动选择服务模式 Implementation Plan

> **给代理执行者：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务逐步实现本计划。所有步骤都使用复选框 `- [ ]` 语法追踪。

**目标：** 让安装器根据 backend 自动选择 `LaunchDaemon` 或 `LaunchAgent`，从而使 `tmpfs` 以 root 权限可用，同时保持 `apfs` 的用户级安装路径。

**架构：** 保持项目为小型 POSIX `sh` 工具集，但将“运行时挂载逻辑”和“服务安装逻辑”明确分层。`src/create_memory_cache.sh` 继续作为唯一运行时入口；`install.sh` 和 `uninstall.sh` 根据 backend 决定安装到用户路径还是系统路径，并在切换 backend 时负责清理另一种服务模式的安装产物。

**技术栈：** POSIX `sh`、macOS `launchctl`、`mount_tmpfs`、`hdiutil`、`diskutil`、shell 测试脚本、README 文档。

---

## 全局约束

- 所有 shell 脚本必须继续兼容 `/bin/sh`。
- 只支持 `tmpfs` 和 `apfs` 两种 backend。
- `tmpfs` 必须安装为 `LaunchDaemon`。
- `apfs` 必须安装为 `LaunchAgent`。
- 运行时禁止在 backend 之间静默 fallback。
- `tmpfs` 安装在没有 root 权限时必须直接失败，并输出明确错误。
- `apfs` 在普通用户安装时必须继续写入用户目录。
- 切换 backend 时，安装器必须先删除另一种模式的安装产物，再安装新模式。
- 卸载器不得自动 `umount ~/tmpfs`。
- 卸载器不得自动 eject `/Volumes/Ramdisk`。
- 所有新增或更新文档都必须使用简体中文。

## 文件结构

- 修改 [install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh)：根据 backend 安装为 daemon 或 agent，解析目标用户，写入不同路径的配置/脚本/plist，并负责 backend 切换清理。
- 修改 [uninstall.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/uninstall.sh)：同时识别并清理 agent 模式与 daemon 模式安装产物，在需要时要求 `sudo`。
- 修改 [src/create_memory_cache.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/create_memory_cache.sh)：增加 `SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME` 校验；让 `tmpfs` 使用绝对路径并在挂载后修正目录所有权。
- 新建 [src/com.local.memory-cache.agent.plist.template](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/com.local.memory-cache.agent.plist.template)：用户模式 plist 模板。
- 新建 [src/com.local.memory-cache.daemon.plist.template](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/com.local.memory-cache.daemon.plist.template)：系统模式 plist 模板。
- 修改 [tests/install_test.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/tests/install_test.sh)：覆盖 backend 到服务模式的映射、权限要求、切换清理。
- 修改 [tests/runtime_test.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/tests/runtime_test.sh)：覆盖新配置字段、daemon 模式 `tmpfs` 路径与权限修正。
- 修改 [tests/uninstall_test.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/tests/uninstall_test.sh)：覆盖 agent/daemon 双模式清理。
- 修改 [README.md](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/README.md) 和 [README.zh-CN.md](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/README.zh-CN.md)：文档统一改为简体中文，并更新安装模式、日志路径、切换行为。

### Task 1: 建立双模板与安装器测试骨架

**Files:**
- Create: `src/com.local.memory-cache.agent.plist.template`
- Create: `src/com.local.memory-cache.daemon.plist.template`
- Modify: `tests/install_test.sh`

- [ ] **Step 1: 先把安装器测试改成描述新行为的失败用例**

将 [tests/install_test.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/tests/install_test.sh) 替换为：

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
if MEMORY_CACHE_SKIP_LAUNCHCTL=1 HOME="$HOME_DIR" "$ROOT/install.sh" --backend tmpfs >/tmp/memory-cache-install-tmpfs-no-root.out 2>&1; then
  fail "tmpfs install without root unexpectedly succeeded"
fi
grep -Fq "tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root" \
  /tmp/memory-cache-install-tmpfs-no-root.out || fail "missing tmpfs sudo error"

HOME_DIR=$(make_home)
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=25769803776 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER=saber \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR/home" \
HOME="$HOME_DIR/home" \
  "$ROOT/install.sh" --backend tmpfs --size 2g >/tmp/memory-cache-install-daemon.out

DAEMON_CONFIG="$HOME_DIR/Library/Application Support/memory-cache-for-mac/config"
assert_file "$DAEMON_CONFIG"
assert_contains "$DAEMON_CONFIG" "BACKEND=tmpfs"
assert_contains "$DAEMON_CONFIG" "SERVICE_MODE=daemon"
assert_contains "$DAEMON_CONFIG" "TARGET_USER=saber"
assert_contains "$DAEMON_CONFIG" "TARGET_HOME=$HOME_DIR/home"
assert_contains "$DAEMON_CONFIG" "TMPFS_MOUNT_PATH=\"$HOME_DIR/home/tmpfs\""
assert_file "$HOME_DIR/usr/local/libexec/create_memory_cache.sh"
assert_file "$HOME_DIR/Library/LaunchDaemons/com.local.memory-cache.plist"

HOME_DIR=$(make_home)
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_MEMSIZE_BYTES=17179869184 \
HOME="$HOME_DIR/home" \
  "$ROOT/install.sh" --backend apfs >/tmp/memory-cache-install-agent.out

AGENT_CONFIG="$HOME_DIR/home/.config/memory-cache-for-mac/config"
assert_file "$AGENT_CONFIG"
assert_contains "$AGENT_CONFIG" "BACKEND=apfs"
assert_contains "$AGENT_CONFIG" "SERVICE_MODE=agent"
assert_contains "$AGENT_CONFIG" "TARGET_HOME=$HOME_DIR/home"
assert_contains "$AGENT_CONFIG" "APFS_MOUNT_PATH=\"/Volumes/\$APFS_DISK_NAME\""
assert_file "$HOME_DIR/home/.local/bin/create_memory_cache.sh"
assert_file "$HOME_DIR/home/Library/LaunchAgents/com.local.memory-cache.plist"

HOME_DIR=$(make_home)
mkdir -p "$HOME_DIR/home/.local/bin" "$HOME_DIR/home/Library/LaunchAgents" "$HOME_DIR/Library/LaunchDaemons" "$HOME_DIR/usr/local/libexec"
: > "$HOME_DIR/home/.local/bin/create_memory_cache.sh"
: > "$HOME_DIR/home/Library/LaunchAgents/com.local.memory-cache.plist"
: > "$HOME_DIR/Library/LaunchDaemons/com.local.memory-cache.plist"
: > "$HOME_DIR/usr/local/libexec/create_memory_cache.sh"
MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
MEMORY_CACHE_TEST_TARGET_USER=saber \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR/home" \
HOME="$HOME_DIR/home" \
  "$ROOT/install.sh" --backend apfs --size 1g >/tmp/memory-cache-install-switch-to-agent.out
assert_not_exists "$HOME_DIR/Library/LaunchDaemons/com.local.memory-cache.plist"
assert_not_exists "$HOME_DIR/usr/local/libexec/create_memory_cache.sh"
assert_file "$HOME_DIR/home/Library/LaunchAgents/com.local.memory-cache.plist"

echo "install tests passed"
```

- [ ] **Step 2: 运行安装器测试并确认它先失败**

运行：

```sh
sh tests/install_test.sh
```

期望：失败，并指出当前 `install.sh` 仍然写入单一 `LaunchAgent` 路径，且不认识 `MEMORY_CACHE_TEST_EFFECTIVE_UID`、daemon 安装路径等新约束。

- [ ] **Step 3: 新建 agent 模式 plist 模板**

创建 [src/com.local.memory-cache.agent.plist.template](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/com.local.memory-cache.agent.plist.template)：

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

- [ ] **Step 4: 新建 daemon 模式 plist 模板**

创建 [src/com.local.memory-cache.daemon.plist.template](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/com.local.memory-cache.daemon.plist.template)：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.local.memory-cache</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/libexec/create_memory_cache.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/Library/Logs/memory-cache.log</string>
	<key>StandardErrorPath</key>
	<string>/Library/Logs/memory-cache.err.log</string>
</dict>
</plist>
```

- [ ] **Step 5: 运行安装器测试，确认现在仍然因为安装器逻辑未实现而失败**

运行：

```sh
sh tests/install_test.sh
```

期望：依然失败，但不再报“模板文件不存在”，失败点应集中到 `install.sh` 尚未实现 backend 分流。

- [ ] **Step 6: 提交当前测试与模板准备**

运行：

```sh
git add tests/install_test.sh src/com.local.memory-cache.agent.plist.template src/com.local.memory-cache.daemon.plist.template
git commit -m "test: define backend-based install behavior"
```

期望：提交成功，提交中只包含测试与两个 plist 模板。

### Task 2: 重写安装器以支持 backend 决定服务模式

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: 先在 `install.sh` 顶部建立双模式路径与测试钩子**

将 [install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh) 的常量定义替换为：

```sh
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
```

- [ ] **Step 2: 增加目标用户与有效 UID 解析函数**

在 [install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh) 中添加这些函数：

```sh
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
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi
  id -un
}

resolve_target_home() {
  if [ -n "${MEMORY_CACHE_TEST_TARGET_HOME:-}" ]; then
    printf '%s\n' "$MEMORY_CACHE_TEST_TARGET_HOME"
    return
  fi
  user_name=$1
  if [ "$user_name" = "$(id -un 2>/dev/null || printf '%s' '')" ]; then
    printf '%s\n' "$HOME"
    return
  fi
  dscl . -read "/Users/$user_name" NFSHomeDirectory 2>/dev/null | awk 'NR==1 { print $2 }'
}
```

- [ ] **Step 3: 增加根据 service mode 计算安装路径的函数**

在 [install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh) 中添加：

```sh
service_mode_for_backend() {
  case "$1" in
    tmpfs) printf '%s\n' "daemon" ;;
    apfs) printf '%s\n' "agent" ;;
    *) echo "Unsupported backend: $1" >&2; exit 1 ;;
  esac
}

set_paths_for_mode() {
  service_mode=$1
  target_home=$2

  AGENT_SCRIPT="$target_home/.local/bin/create_memory_cache.sh"
  AGENT_PLIST="$target_home/Library/LaunchAgents/$LABEL.plist"
  AGENT_CONFIG_DIR="$target_home/.config/memory-cache-for-mac"
  AGENT_CONFIG_PATH="$AGENT_CONFIG_DIR/config"
  AGENT_LOG_DIR="$target_home/Library/Logs"
  AGENT_LOG_FILE="$AGENT_LOG_DIR/memory-cache.log"
  AGENT_ERR_LOG_FILE="$AGENT_LOG_DIR/memory-cache.err.log"

  DAEMON_SCRIPT="/usr/local/libexec/create_memory_cache.sh"
  DAEMON_PLIST="/Library/LaunchDaemons/$LABEL.plist"
  DAEMON_CONFIG_DIR="/Library/Application Support/memory-cache-for-mac"
  DAEMON_CONFIG_PATH="$DAEMON_CONFIG_DIR/config"
  DAEMON_LOG_DIR="/Library/Logs"
  DAEMON_LOG_FILE="$DAEMON_LOG_DIR/memory-cache.log"
  DAEMON_ERR_LOG_FILE="$DAEMON_LOG_DIR/memory-cache.err.log"

  if [ -n "${MEMORY_CACHE_TEST_TARGET_HOME:-}" ]; then
    sandbox_root=$(dirname "$target_home")
    DAEMON_SCRIPT="$sandbox_root/usr/local/libexec/create_memory_cache.sh"
    DAEMON_PLIST="$sandbox_root/Library/LaunchDaemons/$LABEL.plist"
    DAEMON_CONFIG_DIR="$sandbox_root/Library/Application Support/memory-cache-for-mac"
    DAEMON_CONFIG_PATH="$DAEMON_CONFIG_DIR/config"
    DAEMON_LOG_DIR="$sandbox_root/Library/Logs"
    DAEMON_LOG_FILE="$DAEMON_LOG_DIR/memory-cache.log"
    DAEMON_ERR_LOG_FILE="$DAEMON_LOG_DIR/memory-cache.err.log"
  fi

  case "$service_mode" in
    agent)
      INSTALL_SCRIPT="$AGENT_SCRIPT"
      PLIST_PATH="$AGENT_PLIST"
      CONFIG_DIR="$AGENT_CONFIG_DIR"
      CONFIG_PATH="$AGENT_CONFIG_PATH"
      LOG_DIR="$AGENT_LOG_DIR"
      LOG_FILE="$AGENT_LOG_FILE"
      ERR_LOG_FILE="$AGENT_ERR_LOG_FILE"
      PLIST_TEMPLATE="$AGENT_PLIST_TEMPLATE"
      ;;
    daemon)
      INSTALL_SCRIPT="$DAEMON_SCRIPT"
      PLIST_PATH="$DAEMON_PLIST"
      CONFIG_DIR="$DAEMON_CONFIG_DIR"
      CONFIG_PATH="$DAEMON_CONFIG_PATH"
      LOG_DIR="$DAEMON_LOG_DIR"
      LOG_FILE="$DAEMON_LOG_FILE"
      ERR_LOG_FILE="$DAEMON_ERR_LOG_FILE"
      PLIST_TEMPLATE="$DAEMON_PLIST_TEMPLATE"
      ;;
  esac
}
```

- [ ] **Step 4: 写入包含安装上下文的新配置文件**

将 [install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh) 中原有 `write_config()` 替换为：

```sh
write_config() {
  backend=$1
  service_mode=$2
  cache_size=$3
  target_user=$4
  target_home=$5

  mkdir -p "$CONFIG_DIR"
  tmpfs_mount_path="$target_home/tmpfs"
  cat > "$CONFIG_PATH" <<EOF_CONFIG
BACKEND=$backend
SERVICE_MODE=$service_mode
CACHE_SIZE=$cache_size
TARGET_USER=$target_user
TARGET_HOME=$target_home
TMPFS_MOUNT_PATH="$tmpfs_mount_path"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
  chmod 644 "$CONFIG_PATH"
}
```

- [ ] **Step 5: 增加双模式清理与 bootstrap 逻辑**

在 [install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh) 中加入：

```sh
bootout_agent_if_present() {
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  launchctl bootout "gui/$TARGET_UID" "$AGENT_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$TARGET_UID/$LABEL" >/dev/null 2>&1 || true
}

bootout_daemon_if_present() {
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  launchctl bootout system "$DAEMON_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
}

cleanup_opposite_mode() {
  service_mode=$1
  bootout_agent_if_present
  bootout_daemon_if_present
  rm -f "$AGENT_PLIST" "$AGENT_SCRIPT" "$AGENT_CONFIG_PATH" "$AGENT_LOG_FILE" "$AGENT_ERR_LOG_FILE"
  rm -f "$DAEMON_PLIST" "$DAEMON_SCRIPT" "$DAEMON_CONFIG_PATH" "$DAEMON_LOG_FILE" "$DAEMON_ERR_LOG_FILE"
  rm -f "$TARGET_HOME/.local/bin/create_ram_disk.sh" "$TARGET_HOME/Library/LaunchAgents/$OLD_LABEL.plist"
}

load_service() {
  service_mode=$1
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  case "$service_mode" in
    agent)
      launchctl bootstrap "gui/$TARGET_UID" "$PLIST_PATH"
      launchctl kickstart -k "gui/$TARGET_UID/$LABEL" >/dev/null 2>&1 || true
      ;;
    daemon)
      launchctl bootstrap system "$PLIST_PATH"
      launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
      ;;
  esac
}
```

- [ ] **Step 6: 把主流程替换成 backend 决定模式的安装流程**

把 [install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh) 末尾主流程替换为：

```sh
parse_args "$@"
recommended_backend=$(recommend_backend)
recommended_size=$(recommend_size)
backend=$(choose_backend "$recommended_backend")
cache_size=$(choose_size "$recommended_size")
service_mode=$(service_mode_for_backend "$backend")
target_user=$(resolve_target_user)
target_home=$(resolve_target_home "$target_user")
[ -n "$target_home" ] || { echo "Could not determine home directory for target user: $target_user" >&2; exit 1; }
TARGET_UID=$(id -u "$target_user" 2>/dev/null || printf '%s\n' "${MEMORY_CACHE_TEST_TARGET_UID:-501}")

if [ "$backend" = "tmpfs" ] && [ "$(effective_uid)" -ne 0 ]; then
  echo "tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root" >&2
  exit 1
fi

set_paths_for_mode "$service_mode" "$target_home"
cleanup_opposite_mode "$service_mode"
install_files
write_config "$backend" "$service_mode" "$cache_size" "$target_user" "$target_home"
load_service "$service_mode"

echo "Installed $LABEL"
echo "Backend: $backend"
echo "Service mode: $service_mode"
echo "Config: $CONFIG_PATH"
echo "Script: $INSTALL_SCRIPT"
echo "Plist: $PLIST_PATH"
```

- [ ] **Step 7: 运行安装器测试并确认通过**

运行：

```sh
sh tests/install_test.sh
```

期望：输出 `install tests passed`。

- [ ] **Step 8: 提交安装器重构**

运行：

```sh
git add install.sh
git commit -m "feat: choose service mode from backend"
```

期望：提交成功，仅包含安装器逻辑重构。

### Task 3: 扩展运行时配置与 tmpfs 权限修正

**Files:**
- Modify: `src/create_memory_cache.sh`
- Modify: `tests/runtime_test.sh`

- [ ] **Step 1: 增加运行时测试，先覆盖新配置字段与 daemon tmpfs 行为**

在 [tests/runtime_test.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/tests/runtime_test.sh) 末尾追加：

```sh
HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=tmpfs
CACHE_SIZE=1g
TARGET_USER=saber
TARGET_HOME=$HOME_DIR
TMPFS_MOUNT_PATH="$HOME_DIR/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-missing-service-mode.out 2>&1; then
  fail "missing SERVICE_MODE unexpectedly succeeded"
fi
grep -Fq "Missing required config: SERVICE_MODE" /tmp/memory-cache-runtime-missing-service-mode.out || fail "missing SERVICE_MODE error not found"

HOME_DIR=$(make_home)
CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
mkdir -p "$(dirname "$CONFIG")"
cat > "$CONFIG" <<EOF_CONFIG
BACKEND=tmpfs
SERVICE_MODE=daemon
CACHE_SIZE=1g
TARGET_USER=saber
TARGET_HOME=$HOME_DIR
TMPFS_MOUNT_PATH="$HOME_DIR/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/\$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
EOF_CONFIG

STUB_DIR="$HOME_DIR/bin-stubs-chown"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/mount_tmpfs" <<'EOF_STUB'
#!/bin/sh
mkdir -p "$3"
exit 0
EOF_STUB
chmod 755 "$STUB_DIR/mount_tmpfs"

cat > "$STUB_DIR/chown" <<'EOF_STUB'
#!/bin/sh
echo "$*" >> "$0.calls"
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
  MOUNT_CMD="$STUB_DIR/mount" \
  CHOWN_CMD="$STUB_DIR/chown" \
  "$SCRIPT" >/tmp/memory-cache-runtime-daemon-tmpfs.out 2>&1; then
  fail "daemon tmpfs runtime unexpectedly failed"
fi
grep -Fq "saber $HOME_DIR/tmpfs" "$STUB_DIR/chown.calls" || fail "tmpfs root ownership fix not recorded"
```

- [ ] **Step 2: 运行运行时测试并确认新增用例先失败**

运行：

```sh
sh tests/runtime_test.sh
```

期望：失败，并指出 `SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME` 还不是必填项，且脚本还没有 `CHOWN_CMD` 钩子。

- [ ] **Step 3: 为运行时增加 chown 测试钩子与新配置字段**

把 [src/create_memory_cache.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/create_memory_cache.sh) 顶部命令注入段替换为：

```sh
if [ "${MEMORY_CACHE_TEST_COMMANDS:-0}" = "1" ]; then
  MOUNT_TMPFS_CMD=${MOUNT_TMPFS_CMD:-mount_tmpfs}
  HDIUTIL_CMD=${HDIUTIL_CMD:-hdiutil}
  DISKUTIL_CMD=${DISKUTIL_CMD:-diskutil}
  MOUNT_CMD=${MOUNT_CMD:-mount}
  CHOWN_CMD=${CHOWN_CMD:-chown}
else
  MOUNT_TMPFS_CMD=mount_tmpfs
  HDIUTIL_CMD=hdiutil
  DISKUTIL_CMD=diskutil
  MOUNT_CMD=mount
  CHOWN_CMD=chown
fi
```

- [ ] **Step 4: 让运行时强制校验安装上下文**

将 [src/create_memory_cache.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/create_memory_cache.sh) 中 `load_config()` 的变量和校验替换为：

```sh
load_config() {
  [ -f "$CONFIG_PATH" ] || fail "Missing config: $CONFIG_PATH. Re-run ./install.sh."
  unset BACKEND SERVICE_MODE CACHE_SIZE TARGET_USER TARGET_HOME TMPFS_MOUNT_PATH APFS_DISK_NAME APFS_MOUNT_PATH CREATE_DIRS
  # shellcheck disable=SC1090
  . "$CONFIG_PATH"

  require_config_var BACKEND
  require_config_var SERVICE_MODE
  require_config_var CACHE_SIZE
  require_config_var TARGET_USER
  require_config_var TARGET_HOME
  require_config_var TMPFS_MOUNT_PATH
  require_config_var APFS_DISK_NAME
  require_config_var APFS_MOUNT_PATH
  require_config_var CREATE_DIRS

  case "$BACKEND" in
    tmpfs|apfs) ;;
    *) fail "Unsupported backend: $BACKEND" ;;
  esac

  case "$SERVICE_MODE" in
    agent|daemon) ;;
    *) fail "Unsupported service mode: $SERVICE_MODE" ;;
  esac

  CACHE_SIZE=$(normalize_size "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"

  if [ "$BACKEND" = "apfs" ]; then
    validate_apfs_disk_name
    expected_apfs_mount_path="/Volumes/$APFS_DISK_NAME"
    [ "$APFS_MOUNT_PATH" = "$expected_apfs_mount_path" ] || fail "APFS_MOUNT_PATH must match $expected_apfs_mount_path for apfs backend"
  fi
}
```

- [ ] **Step 5: 在 tmpfs 路径上增加目录所有权修正**

在 [src/create_memory_cache.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/create_memory_cache.sh) 中新增并使用：

```sh
fix_tmpfs_ownership() {
  "$CHOWN_CMD" "$TARGET_USER" "$TMPFS_MOUNT_PATH" >/dev/null 2>&1 || true
  for dir in $CREATE_DIRS; do
    "$CHOWN_CMD" "$TARGET_USER" "$TMPFS_MOUNT_PATH/$dir" >/dev/null 2>&1 || true
  done
}
```

并把 `mount_tmpfs_backend()` 替换为：

```sh
mount_tmpfs_backend() {
  command -v "$MOUNT_TMPFS_CMD" >/dev/null 2>&1 || fail "tmpfs backend requires mount_tmpfs"

  if is_mounted_at "$TMPFS_MOUNT_PATH"; then
    ensure_child_dirs "$TMPFS_MOUNT_PATH"
    fix_tmpfs_ownership
    echo "Memory cache is already mounted at $TMPFS_MOUNT_PATH"
    return
  fi

  if [ -d "$TMPFS_MOUNT_PATH" ] && [ -n "$(ls -A "$TMPFS_MOUNT_PATH" 2>/dev/null)" ]; then
    fail "Refusing to mount over non-empty directory: $TMPFS_MOUNT_PATH"
  fi

  mkdir -p "$TMPFS_MOUNT_PATH"
  "$MOUNT_TMPFS_CMD" -i -s "$CACHE_SIZE" "$TMPFS_MOUNT_PATH" || fail "mount_tmpfs failed"
  ensure_child_dirs "$TMPFS_MOUNT_PATH"
  fix_tmpfs_ownership
}
```

- [ ] **Step 6: 运行运行时测试并确认通过**

运行：

```sh
sh tests/runtime_test.sh
```

期望：输出 `runtime tests passed`。

- [ ] **Step 7: 提交运行时重构**

运行：

```sh
git add src/create_memory_cache.sh tests/runtime_test.sh
git commit -m "feat: support daemon tmpfs runtime context"
```

期望：提交成功，仅包含运行时与运行时测试变更。

### Task 4: 让卸载器识别并清理双模式安装

**Files:**
- Modify: `uninstall.sh`
- Modify: `tests/uninstall_test.sh`

- [ ] **Step 1: 先把卸载测试扩展到 agent 和 daemon 双模式**

将 [tests/uninstall_test.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/tests/uninstall_test.sh) 替换为：

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
SANDBOX_ROOT=$(dirname "$HOME_DIR")
mkdir -p \
  "$HOME_DIR/.local/bin" \
  "$HOME_DIR/Library/LaunchAgents" \
  "$HOME_DIR/Library/Logs" \
  "$HOME_DIR/.config/memory-cache-for-mac" \
  "$SANDBOX_ROOT/Library/LaunchDaemons" \
  "$SANDBOX_ROOT/usr/local/libexec" \
  "$SANDBOX_ROOT/Library/Application Support/memory-cache-for-mac" \
  "$SANDBOX_ROOT/Library/Logs" \
  "$HOME_DIR/tmpfs"

: > "$HOME_DIR/.local/bin/create_memory_cache.sh"
: > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
: > "$HOME_DIR/.config/memory-cache-for-mac/config"
: > "$HOME_DIR/Library/Logs/memory-cache.log"
: > "$HOME_DIR/Library/Logs/memory-cache.err.log"
: > "$SANDBOX_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
: > "$SANDBOX_ROOT/usr/local/libexec/create_memory_cache.sh"
: > "$SANDBOX_ROOT/Library/Application Support/memory-cache-for-mac/config"
: > "$SANDBOX_ROOT/Library/Logs/memory-cache.log"
: > "$SANDBOX_ROOT/Library/Logs/memory-cache.err.log"
echo "keep" > "$HOME_DIR/tmpfs/keep.txt"

MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
HOME="$HOME_DIR" \
  "$ROOT/uninstall.sh" >/tmp/memory-cache-uninstall.out

assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
assert_absent "$HOME_DIR/.config/memory-cache-for-mac/config"
assert_absent "$SANDBOX_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
assert_absent "$SANDBOX_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_absent "$SANDBOX_ROOT/Library/Application Support/memory-cache-for-mac/config"
assert_absent "$HOME_DIR/Library/Logs/memory-cache.log"
assert_absent "$HOME_DIR/Library/Logs/memory-cache.err.log"
assert_absent "$SANDBOX_ROOT/Library/Logs/memory-cache.log"
assert_absent "$SANDBOX_ROOT/Library/Logs/memory-cache.err.log"
assert_dir "$HOME_DIR/tmpfs"
[ -f "$HOME_DIR/tmpfs/keep.txt" ] || fail "tmpfs contents were removed"

echo "uninstall tests passed"
```

- [ ] **Step 2: 运行卸载测试并确认先失败**

运行：

```sh
sh tests/uninstall_test.sh
```

期望：失败，因为当前 `uninstall.sh` 只认识用户路径。

- [ ] **Step 3: 让卸载器识别 agent 与 daemon 路径**

将 [uninstall.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/uninstall.sh) 改成如下结构：

```sh
#!/bin/sh

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.local.memory-cache"
OLD_LABEL="com.local.ramdisk"
SKIP_LAUNCHCTL="${MEMORY_CACHE_SKIP_LAUNCHCTL:-0}"
TARGET_HOME="${MEMORY_CACHE_TEST_TARGET_HOME:-$HOME}"
SANDBOX_ROOT=$(dirname "$TARGET_HOME")

AGENT_PLIST_PATH="$TARGET_HOME/Library/LaunchAgents/$LABEL.plist"
AGENT_INSTALL_SCRIPT="$TARGET_HOME/.local/bin/create_memory_cache.sh"
AGENT_CONFIG_PATH="$TARGET_HOME/.config/memory-cache-for-mac/config"
AGENT_LOG_FILE="$TARGET_HOME/Library/Logs/memory-cache.log"
AGENT_ERR_LOG_FILE="$TARGET_HOME/Library/Logs/memory-cache.err.log"

DAEMON_PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
DAEMON_INSTALL_SCRIPT="/usr/local/libexec/create_memory_cache.sh"
DAEMON_CONFIG_PATH="/Library/Application Support/memory-cache-for-mac/config"
DAEMON_LOG_FILE="/Library/Logs/memory-cache.log"
DAEMON_ERR_LOG_FILE="/Library/Logs/memory-cache.err.log"

if [ -n "${MEMORY_CACHE_TEST_TARGET_HOME:-}" ]; then
  DAEMON_PLIST_PATH="$SANDBOX_ROOT/Library/LaunchDaemons/$LABEL.plist"
  DAEMON_INSTALL_SCRIPT="$SANDBOX_ROOT/usr/local/libexec/create_memory_cache.sh"
  DAEMON_CONFIG_PATH="$SANDBOX_ROOT/Library/Application Support/memory-cache-for-mac/config"
  DAEMON_LOG_FILE="$SANDBOX_ROOT/Library/Logs/memory-cache.log"
  DAEMON_ERR_LOG_FILE="$SANDBOX_ROOT/Library/Logs/memory-cache.err.log"
fi
```

- [ ] **Step 4: 增加双 domain bootout 与文件清理**

在 [uninstall.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/uninstall.sh) 中加入：

```sh
bootout_if_needed() {
  domain=$1
  label=$2
  plist=$3
  if [ "$SKIP_LAUNCHCTL" = "1" ]; then
    return
  fi
  launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
}

bootout_if_needed "gui/$(id -u)" "$LABEL" "$AGENT_PLIST_PATH"
bootout_if_needed system "$LABEL" "$DAEMON_PLIST_PATH"
bootout_if_needed "gui/$(id -u)" "$OLD_LABEL" "$TARGET_HOME/Library/LaunchAgents/$OLD_LABEL.plist"

rm -f "$AGENT_PLIST_PATH" "$AGENT_INSTALL_SCRIPT" "$AGENT_CONFIG_PATH" "$AGENT_LOG_FILE" "$AGENT_ERR_LOG_FILE"
rm -f "$DAEMON_PLIST_PATH" "$DAEMON_INSTALL_SCRIPT" "$DAEMON_CONFIG_PATH" "$DAEMON_LOG_FILE" "$DAEMON_ERR_LOG_FILE"
rm -f "$TARGET_HOME/Library/LaunchAgents/$OLD_LABEL.plist" "$TARGET_HOME/.local/bin/create_ram_disk.sh"
```

- [ ] **Step 5: 更新卸载提示文案**

把 [uninstall.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/uninstall.sh) 的输出替换为：

```sh
echo "Uninstalled $LABEL"
echo "Manual cleanup, if desired:"
echo "  umount ~/tmpfs"
echo "  diskutil eject /Volumes/<APFS_DISK_NAME>"
echo "Mount roots are not unmounted or deleted automatically."
```

- [ ] **Step 6: 运行卸载测试并确认通过**

运行：

```sh
sh tests/uninstall_test.sh
```

期望：输出 `uninstall tests passed`。

- [ ] **Step 7: 提交卸载器更新**

运行：

```sh
git add uninstall.sh tests/uninstall_test.sh
git commit -m "feat: uninstall agent and daemon modes"
```

期望：提交成功，仅包含卸载器与卸载测试更新。

### Task 5: 更新 README 并做完整回归

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`

- [ ] **Step 1: 将 README.md 改写为简体中文并更新 backend 模式说明**

把 [README.md](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/README.md) 的开头与安装部分改成：

```md
# memory-cache-for-mac

[中文说明](README.zh-CN.md)

一个小型 macOS 内存缓存工具：根据 backend 在登录后创建易失性的缓存空间。

- `tmpfs` backend 安装为系统级 `LaunchDaemon`
- `apfs` backend 安装为用户级 `LaunchAgent`

## 安装

`tmpfs`：

```sh
sudo ./install.sh --backend tmpfs
```

`apfs`：

```sh
./install.sh --backend apfs
```

切换 backend 时，安装器会自动清理另一种模式留下的安装产物，但不会自动卸载 `~/tmpfs` 或 eject `/Volumes/Ramdisk`。
```

- [ ] **Step 2: 将 README.zh-CN.md 更新为与新安装模型一致**

把 [README.zh-CN.md](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/README.zh-CN.md) 的安装、配置、安装文件和卸载部分改成：

```md
## 安装

`tmpfs` backend 需要 root 权限：

```sh
sudo ./install.sh --backend tmpfs
```

`apfs` backend 继续使用普通用户安装：

```sh
./install.sh --backend apfs
```

## 安装文件

`apfs` / agent 模式：

- `~/.local/bin/create_memory_cache.sh`
- `~/Library/LaunchAgents/com.local.memory-cache.plist`
- `~/Library/Logs/memory-cache.log`
- `~/Library/Logs/memory-cache.err.log`
- `~/.config/memory-cache-for-mac/config`

`tmpfs` / daemon 模式：

- `/usr/local/libexec/create_memory_cache.sh`
- `/Library/LaunchDaemons/com.local.memory-cache.plist`
- `/Library/Logs/memory-cache.log`
- `/Library/Logs/memory-cache.err.log`
- `/Library/Application Support/memory-cache-for-mac/config`
```

- [ ] **Step 3: 运行全部测试**

运行：

```sh
sh tests/install_test.sh
sh tests/runtime_test.sh
sh tests/uninstall_test.sh
```

期望：三个脚本分别输出：

```text
install tests passed
runtime tests passed
uninstall tests passed
```

- [ ] **Step 4: 做手动集成验证**

运行：

```sh
sudo ./install.sh --backend tmpfs --size 1g
mount | grep -F " on /Users/$USER/tmpfs "
find "/Users/$USER/tmpfs" -maxdepth 3 -type d | sort
./install.sh --backend apfs --size 1g
mount | grep -F " on /Volumes/Ramdisk "
find /Volumes/Ramdisk -maxdepth 3 -type d | sort
```

期望：

- `tmpfs` 模式下能看到 `/Users/$USER/tmpfs` 挂载成功，并出现默认目录
- `apfs` 模式下能看到 `/Volumes/Ramdisk` 挂载成功，并出现默认目录

- [ ] **Step 5: 提交文档与回归结果**

运行：

```sh
git add README.md README.zh-CN.md
git commit -m "docs: describe backend-based service modes"
```

期望：提交成功，仅包含 README 更新。

## 自检结果

### Spec 覆盖检查

- spec 中关于 `tmpfs -> LaunchDaemon`、`apfs -> LaunchAgent` 的要求由 Task 1 和 Task 2 覆盖。
- spec 中关于 `SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME` 的要求由 Task 3 覆盖。
- spec 中关于切换 backend 时清理另一种模式的要求由 Task 2 覆盖。
- spec 中关于卸载器需要识别双模式安装的要求由 Task 4 覆盖。
- spec 中关于 README 需要解释权限、路径和切换行为的要求由 Task 5 覆盖。
- spec 中关于测试扩展的要求由 Task 1、Task 3、Task 4、Task 5 覆盖。

### 占位符检查

- 计划中没有 `TBD`、`TODO`、`implement later` 之类的占位符。
- 所有命令都写出了明确路径和预期结果。
- 每个代码步骤都给出了具体代码块，而不是抽象描述。

### 类型与命名一致性检查

- `SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME` 在测试、安装器和运行时中保持同名。
- `agent` 与 `daemon` 作为 service mode 枚举值在所有步骤中保持一致。
- `com.local.memory-cache` 作为 label 在 agent 与 daemon 两种模式中保持一致。
