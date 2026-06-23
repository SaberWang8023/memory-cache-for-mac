# 移除运行时配置文件实施计划

> **给代理执行者：** 必须使用子技能 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 逐任务执行本计划。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 删除运行时 config 文件，让 backend、service mode、容量和目标用户信息在安装期固化到已安装运行脚本中。

**架构：** 继续维护单一源码脚本 `src/create_memory_cache.sh`。`install.sh` 在安装时生成带常量块的运行脚本副本；运行时只读取自身常量并派生固定路径，不再查找或 source 配置文件。

**技术栈：** POSIX `sh`、macOS `launchctl`/`mount_tmpfs`/`hdiutil`/`diskutil`、现有 shell 测试脚本。

## 全局约束

- 所有文档和输出使用简体中文；代码标识符、命令、路径和协议字段保持原文。
- 不新增 backend。
- 不保留用户可编辑的运行时配置。
- 不把运行时拆成两个独立源码脚本。
- 不改变现有安装命令；修改容量通过重新运行 `install.sh --backend ... --size ...` 完成。
- 不允许配置挂载路径。
- 新安装不创建 config 文件。
- 卸载和切换 backend 必须继续删除旧 config 路径。

---

## 文件结构

- 修改 `src/create_memory_cache.sh`：删除 config 发现和加载逻辑；改为校验安装期常量并派生固定运行时值。
- 修改 `install.sh`：删除 `write_config`，安装运行脚本时注入常量块；保留旧 config 清理。
- 修改 `tests/runtime_test.sh`：改用带嵌入常量的临时运行脚本，不再为每个 case 写 config。
- 修改 `tests/install_test.sh`：断言不创建 config，并断言已安装运行脚本包含安装期常量。
- 修改 `README.md` 和 `README.zh-CN.md`：删除配置章节，说明容量通过重跑安装命令修改。
- 视结果修改 `tests/uninstall_test.sh`：保留旧 config 清理断言；如果现有覆盖已足够，只做最小调整。

---

### Task 1：运行时停止读取 config

**文件：**
- 修改：`tests/runtime_test.sh`
- 修改：`src/create_memory_cache.sh`

**接口：**
- 消费：已安装脚本或测试临时脚本顶部提供的 `BACKEND`、`CACHE_SIZE`、`SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME`
- 产出：`load_embedded_runtime_config`，负责校验常量并派生 `TMPFS_MOUNT_PATH`、`APFS_DISK_NAME`、`APFS_MOUNT_PATH`、`CREATE_DIRS`

- [ ] **步骤 1: 写失败测试，证明源 runtime 没有嵌入常量时清晰失败**

在 `tests/runtime_test.sh` 开头替换当前 “missing config” 测试：

```sh
HOME_DIR=$(make_home)
if HOME="$HOME_DIR" "$SCRIPT" >/tmp/memory-cache-runtime-missing-constants.out 2>&1; then
  fail "missing embedded constants unexpectedly succeeded"
fi
grep -Fq "Missing installed constant: BACKEND" /tmp/memory-cache-runtime-missing-constants.out || fail "missing constants error not found"
```

- [ ] **步骤 2: 写测试 helper，生成带常量块的临时 runtime**

在 `make_home()` 后加入：

```sh
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
```

把需要运行 runtime 的测试改成：

```sh
RUNTIME="$HOME_DIR/create_memory_cache.sh"
make_runtime_script "$RUNTIME" apfs agent 1g saber "$HOME_DIR"
```

后续命令从 `"$SCRIPT"` 改成 `"$RUNTIME"`。

- [ ] **步骤 3: 运行测试确认失败来自旧 config 逻辑**

执行：

```sh
rtk sh tests/runtime_test.sh
```

预期：FAIL，输出包含旧的 `Missing config` 或旧 config 相关错误。

- [ ] **步骤 4: 实现运行时常量加载**

在 `src/create_memory_cache.sh` 中删除以下函数和调用：

```sh
runtime_daemon_config_path
resolve_default_config_path
load_config_from
load_config
require_config_var
```

删除 `load_config` 调用，替换为：

```sh
load_embedded_runtime_config
```

新增：

```sh
require_installed_constant() {
  var_name=$1
  eval "is_set=\${$var_name+x}"
  [ "$is_set" = x ] || fail "Missing installed constant: $var_name"
  eval "value=\${$var_name}"
  [ -n "$value" ] || fail "Missing installed constant: $var_name"
}

load_embedded_runtime_config() {
  require_installed_constant BACKEND
  require_installed_constant SERVICE_MODE
  require_installed_constant CACHE_SIZE
  require_installed_constant TARGET_USER
  require_installed_constant TARGET_HOME

  case "$SERVICE_MODE" in
    agent|daemon) ;;
    *) fail "Unsupported service mode: $SERVICE_MODE" ;;
  esac

  case "$BACKEND" in
    tmpfs|apfs) ;;
    *) fail "Unsupported backend: $BACKEND" ;;
  esac

  CACHE_SIZE=$(normalize_size "$CACHE_SIZE") || fail "Unsupported cache size: $CACHE_SIZE"
  TMPFS_MOUNT_PATH="$TARGET_HOME/tmpfs"
  APFS_DISK_NAME=Ramdisk
  APFS_MOUNT_PATH="/Volumes/$APFS_DISK_NAME"
  CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
  validate_apfs_disk_name
}
```

- [ ] **步骤 5: 删除 config override 覆盖**

从 `tests/runtime_test.sh` 删除 `MEMORY_CACHE_CONFIG_PATH` override 测试，以及空 `TMPFS_MOUNT_PATH`、缺失 `CREATE_DIRS`、自定义 `APFS_MOUNT_PATH` 这类用户配置测试。它们对应的能力已经被设计删除。

保留并改写这些测试：

```sh
make_runtime_script "$RUNTIME" other agent 1g saber "$HOME_DIR"
```

用于覆盖 `Unsupported backend`。

```sh
make_runtime_script "$RUNTIME" apfs agent bad saber "$HOME_DIR"
```

用于覆盖 `Unsupported cache size`。

```sh
make_runtime_script "$RUNTIME" tmpfs invalid 1g saber "$HOME_DIR"
```

用于覆盖 `Unsupported service mode`。

- [ ] **步骤 6: 运行 runtime 测试确认通过**

执行:

```sh
rtk sh tests/runtime_test.sh
```

预期：`runtime tests passed`

- [ ] **步骤 7: 提交任务 1**

```sh
rtk git add src/create_memory_cache.sh tests/runtime_test.sh
rtk git commit -m "fix: 从运行时移除 config 加载"
```

---

### Task 2：安装器注入运行时常量并停止创建 config

**文件：**
- 修改：`tests/install_test.sh`
- 修改：`install.sh`

**接口：**
- 消费：`install.sh` 已解析出的 `backend`、`cache_size`、`SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME`
- 产出：已安装脚本副本，顶部包含 `BACKEND`、`CACHE_SIZE`、`SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME`

- [ ] **步骤 1: 写失败测试，daemon 安装不再创建 config，并嵌入常量**

在 `tests/install_test.sh` 的 daemon 安装断言处替换 config 断言：

```sh
DAEMON_CONFIG="$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
assert_not_exists "$DAEMON_CONFIG"
DAEMON_SCRIPT="$SYSTEM_ROOT/usr/local/libexec/create_memory_cache.sh"
assert_file "$DAEMON_SCRIPT"
assert_contains "$DAEMON_SCRIPT" "BACKEND='tmpfs'"
assert_contains "$DAEMON_SCRIPT" "CACHE_SIZE='2g'"
assert_contains "$DAEMON_SCRIPT" "SERVICE_MODE='daemon'"
assert_contains "$DAEMON_SCRIPT" "TARGET_USER='saber'"
assert_contains "$DAEMON_SCRIPT" "TARGET_HOME='$HOME_DIR'"
```

- [ ] **步骤 2: 写失败测试，agent 安装不再创建 config，并嵌入常量**

在 agent 安装断言处替换 config 断言：

```sh
AGENT_CONFIG="$HOME_DIR/.config/memory-cache-for-mac/config"
assert_not_exists "$AGENT_CONFIG"
AGENT_SCRIPT="$HOME_DIR/.local/bin/create_memory_cache.sh"
assert_file "$AGENT_SCRIPT"
assert_contains "$AGENT_SCRIPT" "BACKEND='apfs'"
assert_contains "$AGENT_SCRIPT" "CACHE_SIZE='512m'"
assert_contains "$AGENT_SCRIPT" "SERVICE_MODE='agent'"
assert_contains "$AGENT_SCRIPT" "TARGET_HOME='$HOME_DIR'"
```

- [ ] **步骤 3: 写失败测试，切换 backend 时旧 config 仍被清理**

在切换 backend 测试的 fixture 中加入旧 config：

```sh
mkdir -p "$HOME_DIR/.config/memory-cache-for-mac" "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac"
: > "$HOME_DIR/.config/memory-cache-for-mac/config"
: > "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
```

安装后加入断言：

```sh
assert_not_exists "$HOME_DIR/.config/memory-cache-for-mac/config"
assert_not_exists "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
```

- [ ] **步骤 4: 运行 install 测试确认失败**

执行：

```sh
rtk sh tests/install_test.sh
```

预期：FAIL，原因是当前安装器仍创建 config，且运行脚本没有嵌入常量。

- [ ] **步骤 5: 实现 shell 安全 quote**

在 `install.sh` 中加入：

```sh
quote_shell_value() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
```

- [ ] **步骤 6: 用注入常量替代复制运行脚本**

在 `install.sh` 中新增：

```sh
install_runtime_script() {
  {
    sed -n '1p' "$SOURCE_SCRIPT"
    printf '\n'
    printf '%s\n' "# 由 install.sh 安装。修改这些值请重新运行 install.sh。"
    printf 'BACKEND=%s\n' "$(quote_shell_value "$backend")"
    printf 'CACHE_SIZE=%s\n' "$(quote_shell_value "$cache_size")"
    printf 'SERVICE_MODE=%s\n' "$(quote_shell_value "$SERVICE_MODE")"
    printf 'TARGET_USER=%s\n' "$(quote_shell_value "$TARGET_USER")"
    printf 'TARGET_HOME=%s\n' "$(quote_shell_value "$TARGET_HOME")"
    printf '\n'
    sed '1d' "$SOURCE_SCRIPT"
  } > "$INSTALL_SCRIPT"
  chmod 755 "$INSTALL_SCRIPT"
}
```

在 `install_files()` 中把两个分支里的：

```sh
cp "$SOURCE_SCRIPT" "$INSTALL_SCRIPT"
chmod 755 "$INSTALL_SCRIPT"
```

替换成：

```sh
install_runtime_script
```

- [ ] **步骤 7: 删除新 config 写入**

从 `install.sh` 删除：

```sh
CONFIG_DIR=""
CONFIG_PATH=""
```

从 `set_paths_for_mode()` 删除对 `CONFIG_DIR` 和 `CONFIG_PATH` 的赋值。

删除整个 `write_config()` 函数。

从主流程删除：

```sh
write_config "$backend" "$cache_size"
```

从最终输出删除：

```sh
echo "Config: $CONFIG_PATH"
```

- [ ] **步骤 8: 保留旧 config 清理**

确认 `cleanup_opposite_mode()` 仍包含：

```sh
"$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
"$TARGET_HOME/.config/memory-cache-for-mac/config"
```

如果 Step 7 删除变量时误删了这些 literal path，把它们恢复为 literal path。

- [ ] **步骤 9: 运行 install 测试确认通过**

执行：

```sh
rtk sh tests/install_test.sh
```

预期：`install tests passed`

- [ ] **步骤 10: 提交任务 2**

```sh
rtk git add install.sh tests/install_test.sh
rtk git commit -m "fix: 安装时嵌入运行时常量"
```

---

### Task 3：文档和全量验证

**文件：**
- 修改：`README.md`
- 修改：`README.zh-CN.md`
- 修改：`tests/uninstall_test.sh`（仅当现有旧 config 清理覆盖不足时）

**接口：**
- 消费：任务 1 和任务 2 的新行为
- 产出：用户文档不再要求编辑 config；测试覆盖旧 config 清理

- [ ] **步骤 1: 更新 README 安装产物列表**

从 `README.md` 和 `README.zh-CN.md` 的安装产物列表中删除：

```text
/Library/Application Support/memory-cache-for-mac/config
~/.config/memory-cache-for-mac/config
```

- [ ] **步骤 2: 替换配置章节**

在两个 README 中删除原配置示例，改成：

~~~md
## 修改容量

容量在安装时写入已安装的运行脚本。后续如需修改容量，请重新运行安装命令：

```sh
./install.sh --backend apfs --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

挂载路径和默认缓存目录固定；当前版本不支持通过配置文件修改。
~~~

- [ ] **步骤 3: 检查卸载测试对旧 config 清理的覆盖**

执行：

```sh
rtk rg -n "AGENT_CONFIG_PATH|DAEMON_CONFIG_PATH|config" tests/uninstall_test.sh uninstall.sh
```

预期：`uninstall.sh` 中仍有 agent 和 daemon config path；测试中至少创建并断言它们被删除。

如果 `tests/uninstall_test.sh` 没有创建旧 config，加入：

```sh
: > "$HOME_DIR/.config/memory-cache-for-mac/config"
: > "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
```

并加入：

```sh
assert_absent "$HOME_DIR/.config/memory-cache-for-mac/config"
assert_absent "$SYSTEM_ROOT/Library/Application Support/memory-cache-for-mac/config"
```

- [ ] **步骤 4: 运行全量测试**

执行：

```sh
rtk sh tests/install_test.sh
rtk sh tests/runtime_test.sh
rtk sh tests/uninstall_test.sh
```

预期：

```text
install tests passed
runtime tests passed
uninstall tests passed
```

- [ ] **步骤 5: 确认文档没有残留旧配置指引**

执行：

```sh
rtk rg -n "编辑配置|配置示例|MEMORY_CACHE_CONFIG_PATH|CONFIG_PATH|config path|/memory-cache-for-mac/config" README.md README.zh-CN.md docs/superpowers/specs/2026-06-23-remove-runtime-config-design.md
```

预期：README 中不再出现让用户编辑 config 的说明；spec 中只保留旧 config 迁移清理说明。

- [ ] **步骤 6: 提交任务 3**

```sh
rtk git add README.md README.zh-CN.md tests/uninstall_test.sh
rtk git commit -m "docs: 说明容量通过重新安装修改"
```

---

## 自检记录

- spec 的“删除运行时 config”“安装期固化 size”“不配置挂载路径”分别由 Task 1、Task 2、Task 3 覆盖。
- 旧 config 迁移清理由 Task 2 的 backend 切换测试和 Task 3 的 uninstall 覆盖确认。
- 没有新增 backend，没有拆分运行时源码脚本。
- 每个任务都有独立测试命令和提交点。
