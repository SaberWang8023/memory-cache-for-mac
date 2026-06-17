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
umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
