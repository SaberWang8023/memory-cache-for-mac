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

`tmpfs` backend 会安装为 `LaunchDaemon`。脚本和 `plist` 写入系统路径，运行时以 root 挂载 `tmpfs`，再把目录所有权修正给目标用户，所以安装时必须使用 `sudo`。

`apfs` backend 会安装为 `LaunchAgent`。脚本和 `plist` 只写入当前用户目录，挂载点固定为 `/Volumes/<APFS_DISK_NAME>`，默认就是 `/Volumes/Ramdisk`。

安装脚本不会在 backend 之间静默回退。如果选定的 backend 无法工作，运行时会直接报错退出。

`tmpfs` 和 `apfs` 可以同时安装。默认安装仍只安装推荐 backend；如果想同时使用两者，可以分别执行：

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
```

重复安装同一个 backend 会覆盖该 backend 的脚本和 plist，但不会删除另一个 backend，也不会自动重建已经挂载的 tmpfs 或 APFS ramdisk。修改 `--size` 后，如果对应 backend 已经挂载，需要手动清理挂载点并重启 service 才会立即使用新容量。

## 容量建议

安装器会根据物理内存给出默认容量建议：

| 物理内存 | 推荐容量 |
| --- | --- |
| `<= 16 GB` | `512m` |
| `> 16 GB` 且 `<= 48 GB` | `1g` |
| `> 48 GB` | `2g` |

这只是默认值。你可以在安装时改成别的容量。

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
/Library/Logs/memory-cache.log
/Library/Logs/memory-cache.err.log
```

挂载点默认位于目标用户的 `~/tmpfs`。

### `apfs` 安装产物

```text
~/.local/bin/create_memory_cache.sh
~/Library/LaunchAgents/com.local.memory-cache.plist
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

## 修改容量

容量在安装时写入已安装的运行脚本。后续如需修改容量，请重新运行安装命令：

```sh
./install.sh --backend apfs --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

挂载路径和默认缓存目录固定；当前版本不支持通过配置文件修改。

## 从 ramdisk-for-mac 迁移

安装当前版本时，会停止并删除旧的 `com.local.ramdisk` plist 与 `create_ram_disk.sh`。

已有的 `/Volumes/Ramdisk` 不会被自动 eject。如果确认卷里的内容已经不需要，可以手动执行：

```sh
diskutil eject /Volumes/Ramdisk
```

## 卸载

```sh
./uninstall.sh --backend apfs
sudo ./uninstall.sh --backend tmpfs
sudo ./uninstall.sh --all
```

不带参数时，如果只发现一个 backend，会卸载该 backend；如果两个 backend 都存在，会要求明确指定 `--backend apfs`、`--backend tmpfs` 或 `--all`。

`--all` 包含 tmpfs 时必须从一开始就使用 `sudo`。卸载会移除目标 backend 的安装文件、旧配置清理产物和日志，但不会自动做下面这些事：

- 不会自动卸载 `~/tmpfs`
- 不会自动删除 `~/tmpfs` 目录
- 不会自动 eject `/Volumes/<APFS_DISK_NAME>`
- 不会自动删除 `/Volumes/<APFS_DISK_NAME>` 中原有内容

需要时请手动清理：

```sh
umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
