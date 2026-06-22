# memory-cache-for-mac

[中文补充说明](README.zh-CN.md)

一个用于 macOS 的易失性内存缓存安装脚本，会按照 backend 选择不同的 service mode，在登录后自动准备缓存目录或卷。

当前实现只有两种受支持的组合：

| Backend | Service mode | 默认挂载路径 | 安装权限 |
| --- | --- | --- | --- |
| `tmpfs` | `LaunchDaemon` | `~/tmpfs` | 需要 `sudo` |
| `apfs` | `LaunchAgent` | `/Volumes/Ramdisk` | 当前用户即可安装 |

不要把必须在注销、重启、卸载挂载点、eject 卷或重新安装后继续保留的数据放在这里。

## 使用场景

- 临时下载目录
- 浏览器缓存
- 音乐应用缓存
- 构建缓存或其他可丢弃的 scratch 数据

## Backend 与 service mode

`tmpfs` backend 会安装为 `LaunchDaemon`。脚本和配置写入系统路径，运行时以 root 挂载 `tmpfs`，再把目录所有权修正给目标用户，所以安装时必须使用 `sudo`。

`apfs` backend 会安装为 `LaunchAgent`。脚本和配置只写入当前用户目录，挂载点固定为 `/Volumes/<APFS_DISK_NAME>`，默认就是 `/Volumes/Ramdisk`。

安装脚本不会在 backend 之间静默回退。如果选定的 backend 无法工作，运行时会直接报错退出。

当你从一种 backend 切换到另一种 backend 时，安装脚本会自动停止并清理另一种 service mode 的安装产物，包括：

- plist
- 安装脚本
- 配置文件
- 对应日志文件
- 旧版 `com.local.ramdisk` 兼容产物

它不会自动卸载 `~/tmpfs`，也不会自动 eject 现有的 APFS 卷。

## 容量建议

安装器会根据物理内存给出默认容量建议：

| 物理内存 | 推荐容量 |
| --- | --- |
| `<= 16 GB` | `512m` |
| `> 16 GB` 且 `<= 48 GB` | `1g` |
| `> 48 GB` | `2g` |

这只是默认值。你可以在安装时改成别的容量，后续也可以手动编辑配置。

## 安装

交互式安装：

```sh
./install.sh
```

非交互示例：

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

### `tmpfs` 安装产物

```text
/usr/local/libexec/create_memory_cache.sh
/Library/LaunchDaemons/com.local.memory-cache.plist
/Library/Application Support/memory-cache-for-mac/config
/Library/Logs/memory-cache.log
/Library/Logs/memory-cache.err.log
```

挂载点默认位于目标用户的 `~/tmpfs`。

### `apfs` 安装产物

```text
~/.local/bin/create_memory_cache.sh
~/Library/LaunchAgents/com.local.memory-cache.plist
~/.config/memory-cache-for-mac/config
~/Library/Logs/memory-cache.log
~/Library/Logs/memory-cache.err.log
```

挂载点默认位于 `/Volumes/Ramdisk`。

### 默认缓存目录

无论使用哪种 backend，挂载成功后都会在缓存根目录下创建：

```text
Downloads
Cache/Chrome
Cache/Music
```

## 配置

`tmpfs` 和 `apfs` 分别使用不同位置的配置文件：

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

说明：

- `TMPFS_MOUNT_PATH` 可以改成别的用户目录路径。
- `APFS_MOUNT_PATH` 必须保持为 `/Volumes/$APFS_DISK_NAME`。
- 如果想改 APFS 挂载点名称，只能修改 `APFS_DISK_NAME`，从而改变派生出的 `/Volumes/<name>`。
- 不支持把 APFS backend 挂载到任意自定义路径。

## 从 ramdisk-for-mac 迁移

安装当前版本时，会停止并删除旧的 `com.local.ramdisk` plist 与 `create_ram_disk.sh`。

已有的 `/Volumes/Ramdisk` 不会被自动 eject。如果确认卷里的内容已经不需要，可以手动执行：

```sh
diskutil eject /Volumes/Ramdisk
```

## 卸载

```sh
./uninstall.sh
```

卸载会移除两种 mode 的安装文件、配置和日志，但不会自动做下面这些事：

- 不会自动卸载 `~/tmpfs`
- 不会自动删除 `~/tmpfs` 目录
- 不会自动 eject `/Volumes/<APFS_DISK_NAME>`
- 不会自动删除 `/Volumes/<APFS_DISK_NAME>` 中原有内容

需要时请手动清理：

```sh
umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
