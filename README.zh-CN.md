# memory-cache-for-mac

[README](README.md)

这是这份项目的中文说明，内容与当前实现保持一致。

项目会在 macOS 上创建一个易失性的内存缓存，并根据 backend 选择不同的 service mode：

| Backend | Service mode | 默认挂载路径 | 安装权限 |
| --- | --- | --- | --- |
| `tmpfs` | `LaunchDaemon` | `~/tmpfs` | 需要 root，使用 `sudo` 安装 |
| `apfs` | `LaunchAgent` | `/Volumes/Ramdisk` | 用户级安装 |

## 适用场景

- 临时下载
- 浏览器缓存
- 音乐应用缓存
- 构建缓存和其他可丢弃的工作目录

不要把必须跨注销、重启、卸载挂载点、eject 卷或重新安装后继续存在的数据放在这里。

## 当前 backend 模型

### `tmpfs`

- 安装命令：`sudo ./install.sh --backend tmpfs`
- service mode：`LaunchDaemon`
- 需要 root 的原因：会把脚本装到系统目录，并由 root 挂载 `tmpfs`
- 默认挂载点：目标用户的 `~/tmpfs`
- 安装文件路径：
  - `/usr/local/libexec/create_memory_cache.sh`
  - `/Library/LaunchDaemons/com.local.memory-cache.plist`
  - `/Library/Application Support/memory-cache-for-mac/config`
- 日志路径：
  - `/Library/Logs/memory-cache.log`
  - `/Library/Logs/memory-cache.err.log`

### `apfs`

- 安装命令：`./install.sh --backend apfs`
- service mode：`LaunchAgent`
- 安装级别：当前用户
- 默认挂载点：`/Volumes/Ramdisk`
- 安装文件路径：
  - `~/.local/bin/create_memory_cache.sh`
  - `~/Library/LaunchAgents/com.local.memory-cache.plist`
  - `~/.config/memory-cache-for-mac/config`
- 日志路径：
  - `~/Library/Logs/memory-cache.log`
  - `~/Library/Logs/memory-cache.err.log`

## 切换 backend 时会发生什么

从 `tmpfs` 切换到 `apfs`，或从 `apfs` 切换到 `tmpfs` 时，安装脚本会自动清理另一种 mode 的安装产物，包括：

- plist
- 安装脚本
- 配置文件
- 对应日志
- 旧版 `com.local.ramdisk` 兼容文件

它不会自动做这些事情：

- 不会自动卸载 `~/tmpfs`
- 不会自动删除 `~/tmpfs`
- 不会自动 eject 现有 APFS 卷
- 不会自动清空 `/Volumes/<APFS_DISK_NAME>` 里的内容

运行时也不会在 backend 之间静默回退。选定 backend 失败时会直接报错退出。

## 容量

安装器会根据物理内存给出推荐值：

| 物理内存 | 推荐容量 |
| --- | --- |
| `<= 16 GB` | `512m` |
| `> 16 GB` 且 `<= 48 GB` | `1g` |
| `> 48 GB` | `2g` |

你可以在安装时覆盖这个值，也可以之后直接改配置文件。

## 安装

交互式安装：

```sh
./install.sh
```

常见安装命令：

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

挂载完成后，缓存根目录下默认会创建：

```text
Downloads
Cache/Chrome
Cache/Music
```

## 配置

两种 mode 的配置文件路径不同：

- `tmpfs`：`/Library/Application Support/memory-cache-for-mac/config`
- `apfs`：`~/.config/memory-cache-for-mac/config`

配置示例：

```sh
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
```

约束如下：

- `TMPFS_MOUNT_PATH` 可以改。
- `APFS_MOUNT_PATH` 必须等于 `/Volumes/$APFS_DISK_NAME`。
- 如果要改 APFS 卷名，请修改 `APFS_DISK_NAME`。
- 不支持把 APFS backend 绑定到任意自定义路径。

## 迁移说明

如果你之前用的是旧版 `ramdisk-for-mac`，安装当前版本时会停止并删除旧的 `com.local.ramdisk` 与 `create_ram_disk.sh`。

已有 `/Volumes/Ramdisk` 不会被自动 eject；确认无用后可手动执行：

```sh
diskutil eject /Volumes/Ramdisk
```

## 卸载

```sh
./uninstall.sh
```

卸载会移除 agent 和 daemon 两种模式的安装文件、配置文件与日志，但不会自动卸载挂载点，也不会自动 eject 卷。

需要时手动执行：

```sh
umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
