# 隔离 backend 运行时设计

## 目标

将 `tmpfs` 和 `apfs` 从安装、运行、卸载三个层面彻底隔离。

当前项目已经明确：

- `tmpfs` 只应该作为系统级 `LaunchDaemon` 运行
- `apfs` 只应该作为用户级 `LaunchAgent` 运行

因此 daemon 路径不应该包含 APFS 逻辑，agent 路径也不应该包含 tmpfs 逻辑。两套 backend 可以同时安装，用户按需安装或卸载其中一个或两个。

## 非目标

- 不新增 backend。
- 不增加模板生成系统。
- 不保留“安装一个 backend 时自动清理另一个 backend”的互斥模型。
- 不自动卸载 `~/tmpfs`。
- 不自动 eject `/Volumes/Ramdisk`。
- 不在卸载过程中途调用 `sudo`。

## 运行时拆分

运行时源码拆成两个脚本：

- `src/create_tmpfs_cache.sh`
- `src/create_apfs_cache.sh`

### tmpfs runtime

`src/create_tmpfs_cache.sh` 只包含 tmpfs 逻辑：

- 校验安装期注入常量
- 读取 `CACHE_SIZE`
- 读取 `TARGET_USER`
- 读取 `TARGET_HOME`
- 派生 `TMPFS_MOUNT_PATH="$TARGET_HOME/tmpfs"`
- 调用 `mount_tmpfs`
- 创建默认缓存目录
- 修正挂载根目录和默认目录 ownership

它不包含：

- `hdiutil`
- `diskutil`
- `APFS_DISK_NAME`
- `APFS_MOUNT_PATH`
- APFS mount/eject/detach 逻辑

### apfs runtime

`src/create_apfs_cache.sh` 只包含 APFS ramdisk 逻辑：

- 校验安装期注入常量
- 读取 `CACHE_SIZE`
- 固定 `APFS_DISK_NAME=Ramdisk`
- 固定 `APFS_MOUNT_PATH=/Volumes/Ramdisk`
- 调用 `hdiutil attach -nomount`
- 调用 `diskutil partitionDisk`
- 挂载失败时 detach ramdisk
- 创建默认缓存目录

它不包含：

- `mount_tmpfs`
- `TMPFS_MOUNT_PATH`
- `TARGET_USER`
- `TARGET_HOME`
- chown tmpfs ownership 逻辑

### 允许少量重复

两个运行时脚本可以重复少量基础函数，例如：

- `fail`
- `normalize_size`
- `ensure_child_dirs`
- `is_mounted_at`

这里优先选择清晰隔离，而不是为了去重引入模板、生成器或共享 shell library。

## 安装行为

`install.sh` 继续支持现有命令：

```sh
./install.sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

默认推荐逻辑保持不变：

- 有 `mount_tmpfs` 时推荐 `tmpfs`
- 否则推荐 `apfs`
- 无 `--backend` 时只安装推荐的一个 backend

显式安装允许共存：

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
```

这两条命令可以先后执行。后执行的安装不会删除前一个 backend 的当前安装产物。

### 重复安装

重复安装同一个 backend 必须是幂等覆盖：

- 重复执行 `sudo ./install.sh --backend tmpfs` 只覆盖 daemon/tmpfs 的脚本、plist 和日志路径。
- 重复执行 `./install.sh --backend apfs` 只覆盖 agent/apfs 的脚本、plist 和日志路径。
- 重复安装不删除另一个 backend 的当前安装产物。
- 重复安装不自动 `sudo umount ~/tmpfs`。
- 重复安装不自动 eject `/Volumes/Ramdisk`。

如果用户重复安装时修改 `--size`，安装器会更新已安装脚本中的 `CACHE_SIZE`，但不会重建已经挂载的 tmpfs 或 APFS ramdisk。

因此：

- 如果目标 backend 当前没有挂载，下次 service 启动会使用新 size。
- 如果目标 backend 已经挂载，runtime 仍然识别为“已经挂载”，不会为了应用新 size 自动卸载或重建。
- 如需让新 size 立即生效，用户需要自行确认数据可丢弃后手动 `sudo umount ~/tmpfs` 或 `diskutil eject /Volumes/Ramdisk`，再重新启动对应 service。

### tmpfs 安装

`tmpfs` 安装只负责 daemon/tmpfs：

- 要求 root
- 安装 `src/create_tmpfs_cache.sh` 的注入常量副本
- 写入 `/usr/local/libexec/create_tmpfs_cache.sh`
- 写入 `/Library/LaunchDaemons/com.local.memory-cache.plist`
- 写入 `/Library/Logs/memory-cache.log`
- 写入 `/Library/Logs/memory-cache.err.log`
- 清理 daemon mode 下的旧版 `com.local.ramdisk` 和 `create_memory_cache.sh` 兼容产物
- 清理 daemon mode 下的旧 config 文件

它不清理 agent/apfs 的当前安装产物。

### apfs 安装

`apfs` 安装只负责 agent/apfs：

- 不要求 root
- 安装 `src/create_apfs_cache.sh` 的注入常量副本
- 写入 `~/.local/bin/create_apfs_cache.sh`
- 写入 `~/Library/LaunchAgents/com.local.memory-cache.plist`
- 写入 `~/Library/Logs/memory-cache.log`
- 写入 `~/Library/Logs/memory-cache.err.log`
- 清理 agent mode 下的旧版 `com.local.ramdisk` 和 `create_memory_cache.sh` 兼容产物
- 清理 agent mode 下的旧 config 文件

它不清理 daemon/tmpfs 的当前安装产物。

## 卸载行为

`uninstall.sh` 改为按目标卸载。

支持命令：

```sh
./uninstall.sh --backend apfs
sudo ./uninstall.sh --backend tmpfs
sudo ./uninstall.sh --all
```

### 权限规则

只要本次卸载目标包含已经存在的 daemon/tmpfs 安装产物，脚本必须在做任何删除之前要求 root。

如果没有 root，直接失败：

```text
tmpfs uninstall requires sudo because it removes a LaunchDaemon
Run: sudo ./uninstall.sh --backend tmpfs
```

`./uninstall.sh --all` 如果发现 daemon/tmpfs 存在，也必须在开头失败并提示：

```text
tmpfs uninstall requires sudo because it removes a LaunchDaemon
Run: sudo ./uninstall.sh --all
```

卸载脚本不在执行过程中途调用 `sudo`，避免出现 agent/apfs 已删除但 daemon/tmpfs 未删除的半完成状态。

### 不带参数

`./uninstall.sh` 不带参数时：

- 如果只发现 agent/apfs 安装，卸载 agent/apfs。
- 如果只发现 daemon/tmpfs 安装：
  - root 下卸载 daemon/tmpfs。
  - 非 root 下失败并提示 `sudo ./uninstall.sh --backend tmpfs`。
- 如果两者都发现，失败并提示用户明确选择：
  - `./uninstall.sh --backend apfs`
  - `sudo ./uninstall.sh --backend tmpfs`
  - `sudo ./uninstall.sh --all`
- 如果两者都不存在，仍然清理旧版兼容产物中当前权限允许处理的部分，并输出已卸载或无安装产物的结果。

### --backend apfs

只卸载 agent/apfs：

- bootout `gui/<uid>/com.local.memory-cache`
- 删除 `~/Library/LaunchAgents/com.local.memory-cache.plist`
- 删除 `~/.local/bin/create_apfs_cache.sh`
- 删除 `~/Library/Logs/memory-cache.log`
- 删除 `~/Library/Logs/memory-cache.err.log`
- 删除 agent 旧 config 文件
- 删除 agent 旧版 `com.local.ramdisk` 和 `create_memory_cache.sh` 兼容产物

不触碰 daemon/tmpfs 当前安装产物。

### --backend tmpfs

只卸载 daemon/tmpfs：

- 要求 root
- bootout `system/com.local.memory-cache`
- 删除 `/Library/LaunchDaemons/com.local.memory-cache.plist`
- 删除 `/usr/local/libexec/create_tmpfs_cache.sh`
- 删除 `/Library/Logs/memory-cache.log`
- 删除 `/Library/Logs/memory-cache.err.log`
- 删除 daemon 旧 config 文件
- 删除 daemon 旧版 `com.local.ramdisk` 和 `create_memory_cache.sh` 兼容产物

不触碰 agent/apfs 当前安装产物。

### --all

卸载两个 backend 的安装产物：

- 如果 daemon/tmpfs 存在，要求 root。
- 删除 daemon/tmpfs 安装产物。
- 删除 agent/apfs 安装产物。
- 删除两边旧 config 文件。
- 删除两边旧版 `com.local.ramdisk` 兼容产物。

## 不自动清理挂载点

卸载仍不自动执行：

```sh
sudo umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```

卸载完成后继续输出手动清理提示。

## 文档变更

README 需要更新：

- 说明 tmpfs 和 apfs 可以共存。
- 说明默认安装仍只安装推荐的一个 backend。
- 说明显式执行两条安装命令可以安装两个 backend。
- 说明 uninstall 支持 `--backend apfs`、`--backend tmpfs`、`--all`。
- 说明卸载 tmpfs 或 `--all` 包含 tmpfs 时需要 sudo。
- 删除“切换 backend 会清理另一种 service mode 当前产物”的旧表述。

## 测试

安装测试需要覆盖：

- `--backend tmpfs` 只安装 daemon/tmpfs，不删除已有 agent/apfs。
- `--backend apfs` 只安装 agent/apfs，不删除已有 daemon/tmpfs。
- 重复安装 `tmpfs` 会覆盖 daemon/tmpfs 脚本，不删除 agent/apfs。
- 重复安装 `apfs` 会覆盖 agent/apfs 脚本，不删除 daemon/tmpfs。
- 无 `--backend` 时仍只安装推荐 backend。
- daemon runtime 安装副本不包含 APFS 关键字或 APFS 命令。
- agent runtime 安装副本不包含 tmpfs 关键字或 `mount_tmpfs`。

运行时测试需要拆分或重写：

- tmpfs runtime 测试只覆盖 tmpfs 行为。
- apfs runtime 测试只覆盖 APFS 行为。
- 源 runtime 没有安装期注入时必须失败。

卸载测试需要覆盖：

- `--backend apfs` 只删除 agent/apfs，不删除 daemon/tmpfs。
- `--backend tmpfs` 只删除 daemon/tmpfs，不删除 agent/apfs。
- `--all` 删除两边。
- `--all` 在 daemon/tmpfs 存在且非 root 时失败，并且不删除 agent/apfs。
- 不带参数且两边都存在时失败并提示明确选择。
- 不带参数且只存在一个 backend 时卸载该 backend。

## 验收标准

- daemon 安装副本不包含 APFS 运行逻辑。
- agent 安装副本不包含 tmpfs 运行逻辑。
- tmpfs 和 apfs 可以同时安装。
- 安装任一 backend 不删除另一个 backend 的当前安装产物。
- 重复安装同一 backend 只覆盖该 backend 的安装产物。
- 重复安装修改 size 不自动重建已经挂载的 tmpfs 或 APFS ramdisk。
- uninstall 可以按 backend 卸载。
- `--all` 不会中途 sudo；需要 root 时在任何删除前失败。
- README 与 README.zh-CN 都使用简体中文描述新行为。
