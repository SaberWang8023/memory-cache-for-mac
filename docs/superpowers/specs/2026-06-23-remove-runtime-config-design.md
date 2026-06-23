# 移除运行时配置文件设计

## 目标

移除 `memory-cache-for-mac` 的运行时配置文件。

项目现在只有两种受支持的安装形态：

- `tmpfs` 作为 `LaunchDaemon` 运行
- `apfs` 作为 `LaunchAgent` 运行

backend 和 service mode 已经在安装时确定，运行脚本不再需要每次启动时发现或解析配置文件。

## 非目标

- 不新增 backend。
- 不保留用户可编辑的运行时配置。
- 不把运行时拆成两个独立源码脚本。
- 不改变现有安装命令；只补充说明修改容量需要重新安装。
- 不允许配置挂载路径。

## 用户可见行为

`install.sh` 继续支持：

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

`--backend` 仍然选择安装后的 service mode：

- `tmpfs` 安装 daemon 路径，并要求 sudo。
- `apfs` 安装 agent 路径，不要求 sudo。

`--size` 是安装期参数。后续如需修改 cache size，用户重新运行 `install.sh`，传入目标 backend 和 size。安装器会覆盖该 mode 下已安装的运行脚本和 service plist。

安装器不再创建配置文件。新安装不再输出 config path。

## 运行时常量

已安装的运行脚本包含安装器选择出的值：

```sh
BACKEND=tmpfs|apfs
CACHE_SIZE=512m|1g|2g|...
SERVICE_MODE=daemon|agent
TARGET_USER=<resolved user>
TARGET_HOME=<resolved home>
```

运行脚本从这些常量派生剩余值：

```sh
TMPFS_MOUNT_PATH="$TARGET_HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH=/Volumes/Ramdisk
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
```

这些派生值不再可配置。

## 安装流程

`install.sh` 仍然是唯一负责选择 backend、service mode、target user、target home 和 cache size 的地方。

这些值校验通过后，`install.sh` 安装 `src/create_memory_cache.sh`，并在已安装副本的顶部附近注入常量块。`src/` 下的源脚本仍然是唯一维护的运行时实现。

已安装副本必须能在没有外部项目状态的情况下运行；它只依赖当前已经使用的 macOS 命令。

## 运行流程

`src/create_memory_cache.sh` 停止做配置文件发现和加载。

删除：

- `runtime_daemon_config_path`
- `resolve_default_config_path`
- `load_config_from`
- `load_config`
- `require_config_var`
- `MEMORY_CACHE_CONFIG_PATH`

保留保护真实行为的校验：

- `BACKEND` 必须是 `tmpfs` 或 `apfs`。
- `SERVICE_MODE` 必须是 `daemon` 或 `agent`。
- `CACHE_SIZE` 必须能成功规范化。
- `APFS_DISK_NAME` 校验可以保留；在固定值下，它是防御性校验，而不是用户可见配置。

所选 backend 无法挂载时，运行脚本仍然直接失败，不做静默 fallback。

## 卸载和迁移

`uninstall.sh` 必须继续删除旧配置路径：

- `/Library/Application Support/memory-cache-for-mac/config`
- `~/.config/memory-cache-for-mac/config`

这是对旧版本安装产物的迁移清理。

安装时切换 backend，也必须在清理另一种 mode 时继续删除旧配置路径。

## 文档变更

README 文件必须删除配置章节，并替换成更小的规则：

- cache size 在安装时选择
- 通过重新运行 `install.sh --backend ... --size ...` 修改 cache size
- 挂载路径和默认目录固定

安装产物列表必须不再包含配置文件。

## 测试

更新安装测试，断言不会创建配置文件。

保留以下覆盖：

- tmpfs 安装仍然写入 daemon 产物
- apfs 安装仍然写入 agent 产物
- 显式 `--size` 会嵌入已安装运行脚本
- 切换 backend 会移除旧配置文件
- 无效 size 仍然在安装期失败

更新运行时测试，让它们执行带嵌入常量的已安装脚本或 patched runtime script，而不是为每个 case 写配置文件。

保留一个聚焦的运行时测试，覆盖无效嵌入常量的防御性校验。

## 验收标准

- 全新 `tmpfs` 安装不创建配置文件，已安装 daemon runtime 使用所选 size。
- 全新 `apfs` 安装不创建配置文件，已安装 agent runtime 使用所选 size。
- 直接运行没有注入常量的源 runtime 会清晰失败。
- 卸载和切换 backend 仍然移除旧配置文件。
- README 和 README.zh-CN 不再告诉用户编辑 config。
