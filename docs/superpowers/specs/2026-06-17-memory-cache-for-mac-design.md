# memory-cache-for-mac 设计

日期：2026-06-17

## 目标

将 `ramdisk-for-mac` 重命名为 `memory-cache-for-mac`，并把项目重新定位为一个小型 macOS LaunchAgent 配置：在用户登录时创建一个易失的内存缓存空间。

主要使用场景是可丢弃缓存和临时数据：

- 临时下载
- Chrome 缓存
- 音乐应用缓存
- 构建缓存或临时 scratch 缓存

这个工具不适合存放必须在注销、重启、卸载挂载点或安装变更后继续保留的文件。

## Backend 模型

项目将支持两个 backend：

- `tmpfs`：当 macOS 系统可用 `mount_tmpfs` 时，作为默认 backend
- `apfs`：可选的 APFS ramdisk backend，用于兼容性，以及需要真实内存 APFS 卷的用户

推荐使用 `tmpfs`，因为项目的主要目标是创建一个易失缓存目录，而不是一定要创建一个像磁盘一样的 APFS 卷。

保留 `apfs`，因为部分用户可能更偏好或依赖 `/Volumes/Ramdisk`、APFS 行为，或者卷语义。

运行时行为必须尊重配置中的 backend。如果配置的 backend 失败，脚本应明确失败，而不是静默回退到另一个 backend 或普通磁盘目录。

## 默认值

默认容量上限不应写死为单一值，而应由安装器基于当前机器的物理内存给出推荐值。对于 `tmpfs`，容量是最大容量限制，不是预先分配的内存保留。

推荐规则：

- 物理内存小于等于 16 GB：推荐 `512m`
- 物理内存大于 16 GB 且小于等于 48 GB：推荐 `1g`
- 物理内存大于 48 GB：推荐 `2g`

安装器应优先通过 `sysctl -n hw.memsize` 获取物理内存。如果无法检测物理内存，应保守推荐 `512m`，并提示用户可以自行调整。

这只是安装时的推荐值，用户必须可以自行设定最终容量。容量应写入配置文件，后续也可以手动修改。

默认路径：

- `tmpfs`：`~/tmpfs`
- `apfs`：`/Volumes/Ramdisk`

其中 `tmpfs` 路径可由用户修改。APFS 路径由 `APFS_DISK_NAME` 派生，必须匹配 `/Volumes/$APFS_DISK_NAME`，不支持任意 APFS mount path。

挂载后的缓存根目录下默认创建：

- `Downloads`
- `Cache/Chrome`
- `Cache/Music`

`tmpfs` 应使用大小写不敏感行为，以匹配普通 macOS 用户的默认预期。

## 安装体验

`install.sh` 应同时支持交互式和非交互式使用。

支持的调用形式：

```sh
./install.sh
./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
./install.sh --backend tmpfs --size 512m
```

交互式行为：

- 通过检查命令可用性判断 `mount_tmpfs` 是否可用。
- 如果 `mount_tmpfs` 可用，推荐 `tmpfs`，但仍允许选择 `apfs`。
- 如果 `mount_tmpfs` 不可用，推荐 `apfs`。
- 在询问前解释 `tmpfs` 和 APFS ramdisk 的实际取舍。
- 允许按 Enter 选择推荐 backend。
- 根据物理内存计算推荐容量，展示给用户，并允许用户按 Enter 接受或输入自定义容量。

非交互式行为：

- 如果提供了 `--backend`，使用该值。
- 如果提供了 `--size`，使用该容量。
- 如果提供了 `--backend tmpfs`，但 `mount_tmpfs` 不可用，应以清晰错误失败。
- 如果没有提供 backend，选择自动推荐的 backend。
- 如果没有提供容量参数，使用基于物理内存计算出的推荐容量。
- `--size` 至少应支持 `m` 和 `g` 后缀，例如 `512m`、`1g`、`2g`；不支持或不安全的容量格式应清晰失败。

## 配置

安装器应写入一个可编辑配置文件：

```text
~/.config/memory-cache-for-mac/config
```

建议内容：

```sh
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
```

运行脚本每次执行时都应读取这个文件。这样用户可以修改 backend、容量、路径或目录列表，而不需要编辑已安装的脚本。`CACHE_SIZE` 至少应支持 `m` 和 `g` 后缀，例如 `512m`、`1g`、`2g`。其中 `TMPFS_MOUNT_PATH` 可配置；APFS backend 的 `APFS_MOUNT_PATH` 必须保持 `/Volumes/$APFS_DISK_NAME`，如果要改变 APFS 默认路径，只支持修改 `APFS_DISK_NAME`。

## 安装文件

将用户可见的安装文件从旧的 ramdisk 命名改为 memory-cache 命名：

```text
~/.local/bin/create_memory_cache.sh
~/Library/LaunchAgents/com.local.memory-cache.plist
~/Library/Logs/memory-cache.log
~/Library/Logs/memory-cache.err.log
~/.config/memory-cache-for-mac/config
```

APFS backend 仍然可以使用默认 APFS 磁盘名 `Ramdisk`；这个名字只属于 backend 语义，不定义整个项目。

## 从 ramdisk-for-mac 迁移

安装新版本时应清理旧的 launch 资产：

- 如果存在旧的 `com.local.ramdisk` LaunchAgent，则停止它
- 移除 `~/Library/LaunchAgents/com.local.ramdisk.plist`
- 移除 `~/.local/bin/create_ram_disk.sh`

安装器不应自动卸载或弹出已有的 `/Volumes/Ramdisk` 卷。即使它只是临时卷，也可能包含用户数据。README 应提供手动清理说明，让用户自行决定是否弹出。

## 运行时行为

运行脚本应重命名为 `create_memory_cache.sh`。

通用行为：

- 读取 `~/.config/memory-cache-for-mac/config`
- 如果配置文件缺失，清晰失败并建议重新安装
- 校验 `BACKEND`
- 在安全时创建配置的缓存根目录
- 在缓存根目录完成挂载或可用后，创建配置的子目录
- 如果配置的缓存根目录已经挂载且可用，成功退出

`tmpfs` 行为：

- 确保 `TMPFS_MOUNT_PATH` 存在
- 如果该路径已经是挂载点，复用它并确保子目录存在
- 如果该路径存在且为空，在这里挂载 tmpfs
- 如果该路径存在、不是挂载点且非空，失败退出，避免用挂载遮住一个普通目录
- 使用大小写不敏感行为和配置的容量挂载：

```sh
mount_tmpfs -i -s "$CACHE_SIZE" "$TMPFS_MOUNT_PATH"
```

`apfs` 行为：

- 复用当前的 `hdiutil attach ram://...` 流程
- 将 `CACHE_SIZE` 转换为 `hdiutil ram://` 所需的 512 字节块数
- 使用 `diskutil partitionDisk` 将 ram disk 分区为 APFS
- 挂载路径由 `APFS_DISK_NAME` 派生，保持 `/Volumes/$APFS_DISK_NAME`
- 在 APFS 根目录下创建同一组子目录

## 卸载行为

`uninstall.sh` 应：

- 停止新的 LaunchAgent
- 移除新的 plist 和运行脚本
- 移除新的配置文件
- 如果存在旧的 `ramdisk-for-mac` launch 资产，也停止并移除
- 避免自动卸载 `~/tmpfs` 或 `/Volumes/Ramdisk`
- 避免删除 `~/tmpfs` 目录本身
- 打印手动清理提示，例如：

```sh
umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```

避免自动卸载和删除目录，可以让卸载行为更保守：用户可能仍有临时文件被打开，也可能意外在挂载目录里放了普通文件。

## README 更新

README 应：

- 将项目重命名为 `memory-cache-for-mac`
- 将项目描述为 macOS 的易失内存缓存空间
- 解释 `tmpfs` 和 APFS ramdisk 的取舍
- 说明 `tmpfs` 在可用时是默认选择
- 说明用户仍然可以选择 APFS ramdisk
- 记录每个 backend 的默认路径
- 记录基于物理内存的推荐容量规则和默认子目录
- 展示交互式和非交互式安装示例
- 包含临时下载、Chrome 缓存和音乐缓存示例
- 记录从 `ramdisk-for-mac` 迁移的行为
- 记录已有挂载点的手动清理命令

## 测试

实现应通过聚焦的 shell 层检查验证：

- 在支持 `mount_tmpfs` 的系统上，`install.sh --backend tmpfs` 会写入预期配置
- 即使 tmpfs 可用，`install.sh --backend apfs` 也会写入 APFS 配置
- 交互式默认选择可以通过 Enter 接受推荐 backend
- 交互式容量选择可以通过 Enter 接受推荐容量，也可以输入自定义容量
- 不支持的 `--backend` 值会清晰失败
- 不支持的 `--size` 值会清晰失败
- `install.sh --backend tmpfs --size 512m` 会把 `CACHE_SIZE=512m` 写入配置
- 运行脚本会拒绝挂载到非空的普通 `~/tmpfs`
- 运行脚本会复用已经挂载的缓存根目录
- 卸载会移除安装文件，但不会卸载或删除挂载根目录

手动验证应包括：在支持 tmpfs 的 macOS 系统上运行 tmpfs backend，并确认配置的子目录出现在 `~/tmpfs` 下。
