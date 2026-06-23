# 隔离 backend 运行时实施计划

> **给代理执行者：** 必须使用子技能 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 逐任务执行本计划。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 将 `tmpfs` daemon 和 `apfs` agent 拆成互不包含对方 backend 逻辑的运行时、安装和卸载路径，并允许两者共存。

**架构：** 新增两个运行时源码：`src/create_tmpfs_cache.sh` 只包含 tmpfs 逻辑，`src/create_apfs_cache.sh` 只包含 APFS ramdisk 逻辑。`install.sh` 根据 backend 复制对应运行时，不再清理另一种 backend；`uninstall.sh` 按 `--backend` 或 `--all` 选择目标，权限 gate 在删除前完成。

**技术栈：** POSIX `sh`、macOS `launchctl`/`mount_tmpfs`/`hdiutil`/`diskutil`、现有 shell 测试脚本。

## 全局约束

- 所有文档和输出使用简体中文；代码标识符、命令、路径和协议字段保持原文。
- 不新增 backend。
- 不增加模板生成系统。
- 不保留“安装一个 backend 时自动清理另一个 backend”的互斥模型。
- 不自动卸载 `~/tmpfs`。
- 不自动 eject `/Volumes/Ramdisk`。
- 不在卸载过程中途调用 `sudo`。
- 无 `--backend` 时只安装推荐的一个 backend。
- 重复安装同一个 backend 只覆盖该 backend 的安装产物。
- 重复安装修改 size 不自动重建已经挂载的 tmpfs 或 APFS ramdisk。

---

## 文件结构

- 新建 `src/create_tmpfs_cache.sh`：daemon/tmpfs 专用运行时。
- 新建 `src/create_apfs_cache.sh`：agent/apfs 专用运行时。
- 删除 `src/create_memory_cache.sh`：不再维护共用 runtime。
- 修改 `install.sh`：根据 backend 选择对应源码脚本；停止清理 opposite mode 当前安装产物。
- 修改 `uninstall.sh`：新增 `--backend apfs`、`--backend tmpfs`、`--all`，默认按探测结果选择或要求用户明确选择。
- 修改 `tests/runtime_test.sh`：拆分 tmpfs/APFS 行为覆盖，断言两个 runtime 不含对方 backend 关键逻辑。
- 修改 `tests/install_test.sh`：覆盖共存、重复安装、默认推荐和安装副本隔离。
- 修改 `tests/uninstall_test.sh`：覆盖按 backend 卸载、`--all` 权限 gate、默认选择行为。
- 修改 `README.md`、`README.zh-CN.md`：描述可共存安装和目标化卸载。

---

### Task 1：拆分运行时源码

**文件：**
- 新建：`src/create_tmpfs_cache.sh`
- 新建：`src/create_apfs_cache.sh`
- 修改：`tests/runtime_test.sh`
- 删除：`src/create_memory_cache.sh`

**接口：**
- `src/create_tmpfs_cache.sh` 消费安装器注入的 `MEMORY_CACHE_INSTALLED`、`CACHE_SIZE`、`TARGET_USER`、`TARGET_HOME`。
- `src/create_apfs_cache.sh` 消费安装器注入的 `MEMORY_CACHE_INSTALLED`、`CACHE_SIZE`。
- 两个脚本都保留源脚本哨兵 `MEMORY_CACHE_INSTALLED=0`，安装副本必须删除该哨兵并注入 `MEMORY_CACHE_INSTALLED='1'`。

- [ ] **步骤 1：写 runtime 隔离失败测试**

重写 `tests/runtime_test.sh` 的文件头和 helper：

```sh
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
```

加入隔离断言：

```sh
assert_not_contains "$TMPFS_SCRIPT" "hdiutil"
assert_not_contains "$TMPFS_SCRIPT" "diskutil"
assert_not_contains "$TMPFS_SCRIPT" "APFS_MOUNT_PATH"
assert_not_contains "$APFS_SCRIPT" "mount_tmpfs"
assert_not_contains "$APFS_SCRIPT" "TMPFS_MOUNT_PATH"
assert_not_contains "$APFS_SCRIPT" "TARGET_HOME"
assert_not_contains "$APFS_SCRIPT" "TARGET_USER"
```

- [ ] **步骤 2：把源 runtime 缺少安装注入的测试拆成两条**

```sh
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
```

- [ ] **步骤 3：保留 tmpfs 行为测试**

把现有 tmpfs 非空目录拒绝、daemon chown、already-mounted chown 测试改为使用：

```sh
RUNTIME="$HOME_DIR/create_tmpfs_cache.sh"
make_tmpfs_runtime "$RUNTIME" 1g saber "$HOME_DIR"
```

运行命令继续调用 `"$RUNTIME"`。

- [ ] **步骤 4：保留 APFS 行为测试**

把 APFS mountpoint missing + detach 测试改为使用：

```sh
RUNTIME="$HOME_DIR/create_apfs_cache.sh"
make_apfs_runtime "$RUNTIME" 1g
```

保留 `MEMORY_CACHE_TEST_APFS_MOUNT_PATH`，但只允许它在 `MEMORY_CACHE_TEST_COMMANDS=1` 下生效。

- [ ] **步骤 5：运行 runtime 测试确认失败**

执行：

```sh
rtk sh tests/runtime_test.sh
```

预期：FAIL，原因是 `src/create_tmpfs_cache.sh` 和 `src/create_apfs_cache.sh` 尚不存在。

- [ ] **步骤 6：创建 `src/create_tmpfs_cache.sh`**

从当前 `src/create_memory_cache.sh` 复制最小 tmpfs 子集：

```sh
#!/bin/sh

MEMORY_CACHE_INSTALLED=0

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if [ "${MEMORY_CACHE_TEST_COMMANDS:-0}" = "1" ]; then
  MOUNT_TMPFS_CMD=${MOUNT_TMPFS_CMD:-mount_tmpfs}
  MOUNT_CMD=${MOUNT_CMD:-mount}
  CHOWN_CMD=${CHOWN_CMD:-chown}
else
  MOUNT_TMPFS_CMD=mount_tmpfs
  MOUNT_CMD=mount
  CHOWN_CMD=chown
fi

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

is_mounted_at() {
  path=$1
  "$MOUNT_CMD" | grep -Fq " on $path "
}

ensure_child_dirs() {
  root=$1
  for dir in $CREATE_DIRS; do
    mkdir -p "$root/$dir"
  done
}

require_installed_constant() {
  var_name=$1
  eval "is_set=\${$var_name+x}"
  [ "$is_set" = x ] || fail "Missing installed constant: $var_name"
  eval "value=\${$var_name}"
  [ -n "$value" ] || fail "Missing installed constant: $var_name"
}

load_installed_config() {
  require_installed_constant MEMORY_CACHE_INSTALLED
  require_installed_constant CACHE_SIZE
  require_installed_constant TARGET_USER
  require_installed_constant TARGET_HOME
  [ "$MEMORY_CACHE_INSTALLED" = "1" ] || fail "Missing installed constant: MEMORY_CACHE_INSTALLED"
  CACHE_SIZE=$(normalize_size "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
  TMPFS_MOUNT_PATH="$TARGET_HOME/tmpfs"
  CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
}

chown_path_if_needed() {
  path=$1
  "$CHOWN_CMD" "$TARGET_USER" "$path" >/dev/null 2>&1 || fail "Failed to set ownership on $path"
}

fix_tmpfs_ownership() {
  chown_path_if_needed "$TMPFS_MOUNT_PATH"
  for dir in $CREATE_DIRS; do
    chown_path_if_needed "$TMPFS_MOUNT_PATH/$dir"
  done
}

mount_tmpfs_cache() {
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

load_installed_config
mount_tmpfs_cache
```

- [ ] **步骤 7：创建 `src/create_apfs_cache.sh`**

从当前 `src/create_memory_cache.sh` 复制最小 APFS 子集：

```sh
#!/bin/sh

MEMORY_CACHE_INSTALLED=0

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if [ "${MEMORY_CACHE_TEST_COMMANDS:-0}" = "1" ]; then
  HDIUTIL_CMD=${HDIUTIL_CMD:-hdiutil}
  DISKUTIL_CMD=${DISKUTIL_CMD:-diskutil}
  MOUNT_CMD=${MOUNT_CMD:-mount}
else
  HDIUTIL_CMD=hdiutil
  DISKUTIL_CMD=diskutil
  MOUNT_CMD=mount
fi

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
  "$MOUNT_CMD" | grep -Fq " on $path "
}

ensure_child_dirs() {
  root=$1
  for dir in $CREATE_DIRS; do
    mkdir -p "$root/$dir"
  done
}

require_installed_constant() {
  var_name=$1
  eval "is_set=\${$var_name+x}"
  [ "$is_set" = x ] || fail "Missing installed constant: $var_name"
  eval "value=\${$var_name}"
  [ -n "$value" ] || fail "Missing installed constant: $var_name"
}

validate_apfs_disk_name() {
  case "$APFS_DISK_NAME" in
    .|..) fail "Unsupported APFS_DISK_NAME: must be a single volume name" ;;
  esac
  if printf '%s' "$APFS_DISK_NAME" | LC_ALL=C grep '[[:cntrl:]:/]' >/dev/null 2>&1; then
    fail "Unsupported APFS_DISK_NAME: must be a single volume name"
  fi
}

load_installed_config() {
  require_installed_constant MEMORY_CACHE_INSTALLED
  require_installed_constant CACHE_SIZE
  [ "$MEMORY_CACHE_INSTALLED" = "1" ] || fail "Missing installed constant: MEMORY_CACHE_INSTALLED"
  CACHE_SIZE=$(normalize_size "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
  APFS_DISK_NAME=Ramdisk
  APFS_MOUNT_PATH="/Volumes/$APFS_DISK_NAME"
  if [ "${MEMORY_CACHE_TEST_COMMANDS:-0}" = "1" ] && [ -n "${MEMORY_CACHE_TEST_APFS_MOUNT_PATH:-}" ]; then
    APFS_MOUNT_PATH=$MEMORY_CACHE_TEST_APFS_MOUNT_PATH
  fi
  CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
  validate_apfs_disk_name
}

mount_apfs_cache() {
  if is_mounted_at "$APFS_MOUNT_PATH"; then
    ensure_child_dirs "$APFS_MOUNT_PATH"
    echo "Memory cache is already mounted at $APFS_MOUNT_PATH"
    return
  fi
  if [ -d "$APFS_MOUNT_PATH" ]; then
    if [ -n "$(ls -A "$APFS_MOUNT_PATH" 2>/dev/null)" ]; then
      fail "Refusing to mount over non-empty directory: $APFS_MOUNT_PATH"
    fi
    rmdir "$APFS_MOUNT_PATH"
  fi
  blocks=$(size_to_blocks "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
  DISK_ID=$("$HDIUTIL_CMD" attach -nomount "ram://$blocks" | awk 'NR==1 { print $1 }') || fail "hdiutil attach failed"
  [ -n "$DISK_ID" ] || fail "Could not get ramdisk device id"
  if ! "$DISKUTIL_CMD" partitionDisk "$DISK_ID" GPT APFS "$APFS_DISK_NAME" 0; then
    "$HDIUTIL_CMD" detach "$DISK_ID" >/dev/null 2>&1 || true
    fail "diskutil partitionDisk failed"
  fi
  if ! is_mounted_at "$APFS_MOUNT_PATH"; then
    "$HDIUTIL_CMD" detach "$DISK_ID" >/dev/null 2>&1 || true
    fail "APFS volume was not mounted at $APFS_MOUNT_PATH"
  fi
  ensure_child_dirs "$APFS_MOUNT_PATH"
}

load_installed_config
mount_apfs_cache
```

- [ ] **步骤 8：删除旧共用 runtime**

```sh
rtk git rm src/create_memory_cache.sh
```

- [ ] **步骤 9：运行 runtime 测试确认通过**

执行：

```sh
rtk sh tests/runtime_test.sh
```

预期：`runtime tests passed`

- [ ] **步骤 10：提交 Task 1**

```sh
rtk git add src/create_tmpfs_cache.sh src/create_apfs_cache.sh tests/runtime_test.sh
rtk git commit -m "refactor: 拆分 backend 运行时"
```

---

### Task 2：安装器按 backend 安装独立 runtime

**文件：**
- 修改：`install.sh`
- 修改：`tests/install_test.sh`

**接口：**
- `source_script_for_backend "$backend"` 输出 `src/create_tmpfs_cache.sh` 或 `src/create_apfs_cache.sh`。
- `install_runtime_script` 使用当前 `SOURCE_SCRIPT` 注入安装期常量。

- [ ] **步骤 1：更新安装测试的源脚本变量**

把 `tests/install_test.sh` 开头：

```sh
SOURCE_SCRIPT="$ROOT/src/create_memory_cache.sh"
```

改成：

```sh
TMPFS_SOURCE_SCRIPT="$ROOT/src/create_tmpfs_cache.sh"
APFS_SOURCE_SCRIPT="$ROOT/src/create_apfs_cache.sh"
```

并断言：

```sh
assert_contains "$TMPFS_SOURCE_SCRIPT" "MEMORY_CACHE_INSTALLED=0"
assert_contains "$APFS_SOURCE_SCRIPT" "MEMORY_CACHE_INSTALLED=0"
```

- [ ] **步骤 2：写 daemon 安装副本隔离断言**

在 daemon 安装断言后加入：

```sh
assert_contains "$DAEMON_SCRIPT" "mount_tmpfs"
assert_not_exists "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
if grep -Fq "hdiutil" "$DAEMON_SCRIPT" || grep -Fq "diskutil" "$DAEMON_SCRIPT" || grep -Fq "APFS_MOUNT_PATH" "$DAEMON_SCRIPT"; then
  fail "daemon runtime contains APFS logic"
fi
```

如果没有 `assert_not_contains`，新增：

```sh
assert_not_contains() {
  file=$1
  unexpected=$2
  if grep -Fq "$unexpected" "$file"; then
    fail "unexpected '$unexpected' in $file"
  fi
}
```

- [ ] **步骤 3：写 agent 安装副本隔离断言**

在 agent 安装断言后加入：

```sh
assert_contains "$AGENT_SCRIPT" "hdiutil"
assert_contains "$AGENT_SCRIPT" "diskutil"
assert_not_contains "$AGENT_SCRIPT" "mount_tmpfs"
assert_not_contains "$AGENT_SCRIPT" "TMPFS_MOUNT_PATH"
assert_not_contains "$AGENT_SCRIPT" "TARGET_HOME="
assert_not_contains "$AGENT_SCRIPT" "TARGET_USER="
```

- [ ] **步骤 4：把旧“切换到 agent 会删除 daemon”测试改为共存测试**

当前 `tests/install_test.sh` 中 `--backend apfs --size 1g` 后断言 daemon 文件不存在。改为：

```sh
assert_file "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
```

旧 config 文件仍应被删除：

```sh
assert_not_exists "$HOME_DIR/.config/memory-cache-for-mac/config"
assert_not_exists "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
```

- [ ] **步骤 5：增加重复安装覆盖**

在共存测试后追加：

```sh
printf '%s\n' "agent keep" > "$HOME_DIR/.local/bin/create_memory_cache.sh"
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
```

- [ ] **步骤 6：运行安装测试确认失败**

执行：

```sh
rtk sh tests/install_test.sh
```

预期：FAIL，因为 `install.sh` 仍引用旧共用 runtime，且仍清理 opposite mode。

- [ ] **步骤 7：修改 `install.sh` 选择 runtime 源文件**

把全局：

```sh
SOURCE_SCRIPT="$SCRIPT_DIR/src/create_memory_cache.sh"
```

改成：

```sh
TMPFS_SOURCE_SCRIPT="$SCRIPT_DIR/src/create_tmpfs_cache.sh"
APFS_SOURCE_SCRIPT="$SCRIPT_DIR/src/create_apfs_cache.sh"
SOURCE_SCRIPT=""
```

新增：

```sh
source_script_for_backend() {
  case "$1" in
    tmpfs) printf '%s\n' "$TMPFS_SOURCE_SCRIPT" ;;
    apfs) printf '%s\n' "$APFS_SOURCE_SCRIPT" ;;
    *) return 1 ;;
  esac
}
```

在主流程 `backend=$(choose_backend "$recommended_backend")` 后设置：

```sh
SOURCE_SCRIPT=$(source_script_for_backend "$backend")
```

- [ ] **步骤 8：停止安装时清理 opposite mode**

从主流程删除：

```sh
cleanup_opposite_mode
```

保留：

```sh
cleanup_current_mode_legacy
cleanup_legacy_configs
```

`cleanup_legacy_configs` 需要改成只清当前 mode 旧 config：

```sh
cleanup_legacy_config_for_mode() {
  case "$SERVICE_MODE" in
    agent) remove_files_if_present "$TARGET_HOME/.config/memory-cache-for-mac/config" ;;
    daemon) remove_files_if_present "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config" ;;
  esac
}
```

主流程调用：

```sh
cleanup_legacy_config_for_mode
```

- [ ] **步骤 9：调整安装注入常量**

`install_runtime_script()` 对 tmpfs 注入：

```sh
MEMORY_CACHE_INSTALLED='1'
CACHE_SIZE='<size>'
TARGET_USER='<user>'
TARGET_HOME='<home>'
```

对 apfs 注入：

```sh
MEMORY_CACHE_INSTALLED='1'
CACHE_SIZE='<size>'
```

不要向 apfs runtime 注入 `TARGET_USER` 或 `TARGET_HOME`。

- [ ] **步骤 10：运行安装测试确认通过**

执行：

```sh
rtk sh tests/install_test.sh
```

预期：`install tests passed`

- [ ] **步骤 11：提交 Task 2**

```sh
rtk git add install.sh tests/install_test.sh
rtk git commit -m "feat: 安装独立 backend 运行时"
```

---

### Task 3：卸载器按目标卸载

**文件：**
- 修改：`uninstall.sh`
- 修改：`tests/uninstall_test.sh`

**接口：**
- `uninstall.sh --backend apfs` 只卸 agent。
- `uninstall.sh --backend tmpfs` 只卸 daemon。
- `uninstall.sh --all` 卸两边。
- 不带参数时按发现结果选择或失败。

- [ ] **步骤 1：重写卸载测试 fixture helper**

在 `tests/uninstall_test.sh` 中保留 `fail/assert_absent/assert_dir/assert_file`，新增：

```sh
make_uninstall_fixture() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/memory-cache-uninstall.XXXXXX")
  HOME_DIR="$TEST_ROOT/home"
  SYSTEM_ROOT="$TEST_ROOT/system"
  mkdir -p \
    "$HOME_DIR/.local/bin" \
    "$HOME_DIR/Library/LaunchAgents" \
    "$HOME_DIR/Library/Logs" \
    "$HOME_DIR/.config/memory-cache-for-mac" \
    "$HOME_DIR/tmpfs" \
    "$SYSTEM_ROOT/Library/LaunchDaemons" \
    "$SYSTEM_ROOT/usr/local/libexec" \
    "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac" \
    "$SYSTEM_ROOT/Library/Logs"
}

seed_agent_assets() {
  : > "$HOME_DIR/.local/bin/create_memory_cache.sh"
  : > "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  : > "$HOME_DIR/.config/memory-cache-for-mac/config"
  : > "$HOME_DIR/.local/bin/create_ram_disk.sh"
  : > "$HOME_DIR/Library/LaunchAgents/com.local.ramdisk.plist"
  : > "$HOME_DIR/Library/Logs/memory-cache.log"
  : > "$HOME_DIR/Library/Logs/memory-cache.err.log"
}

seed_daemon_assets() {
  : > "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  : > "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
  : > "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
  : > "$SYSTEM_ROOT/Library/Logs/memory-cache.log"
  : > "$SYSTEM_ROOT/Library/Logs/memory-cache.err.log"
  : > "$SYSTEM_ROOT/usr/local/libexec/create_ram_disk.sh"
  : > "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.ramdisk.plist"
}
```

- [ ] **步骤 2：写 `--backend apfs` 测试**

```sh
run_backend_apfs_only_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
  MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
  HOME="$HOME_DIR" \
    "$ROOT/uninstall.sh" --backend apfs >/tmp/memory-cache-uninstall-apfs.out
  assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_absent "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_file "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
}
```

- [ ] **步骤 3：写 `--backend tmpfs` 测试**

```sh
run_backend_tmpfs_only_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
  MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
  MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
  HOME="$HOME_DIR" \
    "$ROOT/uninstall.sh" --backend tmpfs >/tmp/memory-cache-uninstall-tmpfs.out
  assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_file "$HOME_DIR/Library/LaunchAgents/com.local.memory-cache.plist"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_absent "$SYSTEM_ROOT/Library/LaunchDaemons/com.local.memory-cache.plist"
}
```

- [ ] **步骤 4：写 `--all` 非 root 权限 gate 测试**

```sh
run_all_requires_sudo_without_partial_delete_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  STDERR_FILE="$TEST_ROOT/stderr.out"
  if MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_DAEMON_PROBE_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=501 \
    HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" --all >/dev/null 2>"$STDERR_FILE"; then
    fail "--all without sudo unexpectedly succeeded"
  fi
  grep -Fq "tmpfs uninstall requires sudo because it removes a LaunchDaemon" "$STDERR_FILE" || fail "missing --all sudo error"
  assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
}
```

- [ ] **步骤 5：写默认双安装失败测试**

```sh
run_default_requires_choice_when_both_exist_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  STDERR_FILE="$TEST_ROOT/default-both.err"
  if MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
    MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
    MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
    MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
    HOME="$HOME_DIR" \
      "$ROOT/uninstall.sh" >/dev/null 2>"$STDERR_FILE"; then
    fail "default uninstall with both backends unexpectedly succeeded"
  fi
  grep -Fq "Multiple backends are installed" "$STDERR_FILE" || fail "missing multiple backend error"
  assert_file "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_file "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
}
```

- [ ] **步骤 6：写 `--all` root 成功测试**

```sh
run_all_root_test() {
  make_uninstall_fixture
  seed_agent_assets
  seed_daemon_assets
  echo "keep" > "$HOME_DIR/tmpfs/keep.txt"
  MEMORY_CACHE_SKIP_LAUNCHCTL=1 \
  MEMORY_CACHE_TEST_TARGET_HOME="$HOME_DIR" \
  MEMORY_CACHE_TEST_SYSTEM_ROOT="$SYSTEM_ROOT" \
  MEMORY_CACHE_TEST_EFFECTIVE_UID=0 \
  HOME="$HOME_DIR" \
    "$ROOT/uninstall.sh" --all >/tmp/memory-cache-uninstall-all.out
  assert_absent "$HOME_DIR/.local/bin/create_memory_cache.sh"
  assert_absent "$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
  assert_dir "$HOME_DIR/tmpfs"
  [ -f "$HOME_DIR/tmpfs/keep.txt" ] || fail "tmpfs contents were removed"
}
```

- [ ] **步骤 7：运行卸载测试确认失败**

执行：

```sh
rtk sh tests/uninstall_test.sh
```

预期：FAIL，因为 `uninstall.sh` 还没有参数化卸载逻辑。

- [ ] **步骤 8：实现参数解析**

在 `uninstall.sh` 增加：

```sh
TARGET_BACKEND=""
UNINSTALL_ALL=0

usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [--backend tmpfs|apfs] [--all]
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --backend)
        [ "$#" -ge 2 ] || { echo "Missing value for --backend" >&2; exit 1; }
        case "$2" in
          tmpfs|apfs) TARGET_BACKEND=$2 ;;
          *) echo "Unsupported backend: $2" >&2; exit 1 ;;
        esac
        shift 2
        ;;
      --all)
        UNINSTALL_ALL=1
        shift
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
  if [ "$UNINSTALL_ALL" = "1" ] && [ -n "$TARGET_BACKEND" ]; then
    echo "Use either --all or --backend, not both" >&2
    exit 1
  fi
}
```

- [ ] **步骤 9：实现 backend 探测与权限 gate**

新增：

```sh
agent_assets_exist() {
  [ -e "$AGENT_PLIST_PATH" ] ||
  [ -e "$AGENT_INSTALL_SCRIPT" ] ||
  [ -e "$AGENT_CONFIG_PATH" ] ||
  [ -e "$OLD_AGENT_PLIST_PATH" ] ||
  [ -e "$OLD_AGENT_INSTALL_SCRIPT" ]
}

resolve_uninstall_targets() {
  if [ "$UNINSTALL_ALL" = "1" ]; then
    UNINSTALL_APFS=1
    UNINSTALL_TMPFS=1
    return
  fi
  case "$TARGET_BACKEND" in
    apfs) UNINSTALL_APFS=1; UNINSTALL_TMPFS=0; return ;;
    tmpfs) UNINSTALL_APFS=0; UNINSTALL_TMPFS=1; return ;;
  esac
  if agent_assets_exist && daemon_assets_exist; then
    echo "Multiple backends are installed; choose --backend apfs, --backend tmpfs, or --all" >&2
    exit 1
  fi
  if agent_assets_exist; then
    UNINSTALL_APFS=1
    UNINSTALL_TMPFS=0
  elif daemon_assets_exist; then
    UNINSTALL_APFS=0
    UNINSTALL_TMPFS=1
  else
    UNINSTALL_APFS=1
    UNINSTALL_TMPFS=1
  fi
}

require_tmpfs_uninstall_privilege() {
  [ "$UNINSTALL_TMPFS" = "1" ] || return
  daemon_assets_exist || return
  if [ "$(effective_uid)" -ne 0 ]; then
    echo "tmpfs uninstall requires sudo because it removes a LaunchDaemon" >&2
    if [ "$UNINSTALL_ALL" = "1" ]; then
      echo "Run: sudo ./uninstall.sh --all" >&2
    else
      echo "Run: sudo ./uninstall.sh --backend tmpfs" >&2
    fi
    exit 1
  fi
}
```

- [ ] **步骤 10：拆分删除函数**

新增：

```sh
uninstall_apfs() {
  bootout_if_needed "$AGENT_DOMAIN" "$LABEL" "$AGENT_PLIST_PATH"
  bootout_if_needed "$AGENT_DOMAIN" "$OLD_LABEL" "$OLD_AGENT_PLIST_PATH"
  rm -f "$AGENT_PLIST_PATH" "$AGENT_INSTALL_SCRIPT" "$AGENT_CONFIG_PATH"
  rm -f "$AGENT_LOG_FILE" "$AGENT_ERR_LOG_FILE"
  rm -f "$OLD_AGENT_PLIST_PATH" "$OLD_AGENT_INSTALL_SCRIPT"
}

uninstall_tmpfs() {
  bootout_if_needed "$DAEMON_DOMAIN" "$LABEL" "$DAEMON_PLIST_PATH"
  bootout_if_needed "$DAEMON_DOMAIN" "$OLD_LABEL" "$OLD_DAEMON_PLIST_PATH"
  rm -f "$DAEMON_PLIST_PATH" "$DAEMON_INSTALL_SCRIPT" "$DAEMON_CONFIG_PATH"
  rm -f "$DAEMON_LOG_FILE" "$DAEMON_ERR_LOG_FILE"
  rm -f "$OLD_DAEMON_PLIST_PATH" "$OLD_DAEMON_INSTALL_SCRIPT"
}
```

主流程：

```sh
parse_args "$@"
resolve_uninstall_targets
require_tmpfs_uninstall_privilege
[ "$UNINSTALL_APFS" = "1" ] && uninstall_apfs
[ "$UNINSTALL_TMPFS" = "1" ] && uninstall_tmpfs
```

- [ ] **步骤 11：运行卸载测试确认通过**

执行：

```sh
rtk sh tests/uninstall_test.sh
```

预期：`uninstall tests passed`

- [ ] **步骤 12：提交 Task 3**

```sh
rtk git add uninstall.sh tests/uninstall_test.sh
rtk git commit -m "feat: 支持按 backend 卸载"
```

---

### Task 4：文档和全量验证

**文件：**
- 修改：`README.md`
- 修改：`README.zh-CN.md`

**接口：**
- README 描述新的共存安装和目标化卸载行为。

- [ ] **步骤 1：更新 backend/service mode 描述**

在两份 README 中删除“切换 backend 会清理另一种 service mode 当前产物”的旧表述，替换为：

```md
`tmpfs` 和 `apfs` 可以同时安装。默认安装仍只安装推荐 backend；如果想同时使用两者，可以分别执行：

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
```
```

- [ ] **步骤 2：更新重复安装和容量说明**

加入：

```md
重复安装同一个 backend 会覆盖该 backend 的脚本和 plist，但不会删除另一个 backend，也不会自动重建已经挂载的 tmpfs 或 APFS ramdisk。修改 `--size` 后，如果对应 backend 已经挂载，需要手动清理挂载点并重启 service 才会立即使用新容量。
```

- [ ] **步骤 3：更新卸载章节**

替换卸载命令为：

```md
```sh
./uninstall.sh --backend apfs
sudo ./uninstall.sh --backend tmpfs
sudo ./uninstall.sh --all
```

不带参数时，如果只发现一个 backend，会卸载该 backend；如果两个 backend 都存在，会要求明确指定 `--backend apfs`、`--backend tmpfs` 或 `--all`。
```

说明 `--all` 包含 tmpfs 时必须从一开始用 sudo。

- [ ] **步骤 4：运行全量测试**

执行：

```sh
rtk sh tests/runtime_test.sh
rtk sh tests/install_test.sh
rtk sh tests/uninstall_test.sh
```

预期：

```text
runtime tests passed
install tests passed
uninstall tests passed
```

- [ ] **步骤 5：检查旧互斥表述残留**

执行：

```sh
rtk rg -n "切换 backend|清理另一种|opposite|互斥|create_memory_cache.sh|create_tmpfs_cache.sh|create_apfs_cache.sh" README.md README.zh-CN.md install.sh uninstall.sh src tests docs/superpowers/specs/2026-06-23-isolated-backend-runtime-design.md
```

预期：

- README 不再说安装一个 backend 会清理另一个 backend。
- `install.sh` 不再调用 `cleanup_opposite_mode`。
- `src/create_memory_cache.sh` 不存在。
- `src/create_tmpfs_cache.sh` 和 `src/create_apfs_cache.sh` 存在。

- [ ] **步骤 6：提交 Task 4**

```sh
rtk git add README.md README.zh-CN.md
rtk git commit -m "docs: 说明 backend 可共存"
```

---

## 自检记录

- 运行时拆分由 Task 1 覆盖。
- 安装共存、重复安装、默认推荐由 Task 2 覆盖。
- 卸载按目标、`--all` 权限 gate、不带参数行为由 Task 3 覆盖。
- README 中文文档和全量验证由 Task 4 覆盖。
- 没有新增 backend，没有模板生成系统，没有中途 sudo。
