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
- 日志路径：
  - `~/Library/Logs/memory-cache.log`
  - `~/Library/Logs/memory-cache.err.log`

`tmpfs` 和 `apfs` 可以同时安装。默认安装仍只安装推荐 backend；如果想同时使用两者，可以分别执行：

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
```

重复安装同一个 backend 会覆盖该 backend 的脚本和 plist，但不会删除另一个 backend，也不会自动重建已经挂载的 tmpfs 或 APFS ramdisk。修改 `--size` 后，如果对应 backend 已经挂载，需要手动清理挂载点并重启 service 才会立即使用新容量。

运行时也不会在 backend 之间静默回退。选定 backend 失败时会直接报错退出。

## 容量

安装器会根据物理内存给出推荐值：

| 物理内存 | 推荐容量 |
| --- | --- |
| `<= 16 GB` | `512m` |
| `> 16 GB` 且 `<= 48 GB` | `1g` |
| `> 48 GB` | `2g` |

你可以在安装时覆盖这个值。

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

## 修改容量

容量在安装时写入已安装的运行脚本。后续如需修改容量，请重新运行安装命令：

```sh
./install.sh --backend apfs --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

挂载路径和默认缓存目录固定；当前版本不支持通过配置文件修改。

## 迁移说明

如果你之前用的是旧版 `ramdisk-for-mac`，安装当前版本时会停止并删除旧的 `com.local.ramdisk` 与 `create_ram_disk.sh`。

已有 `/Volumes/Ramdisk` 不会被自动 eject；确认无用后可手动执行：

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

`--all` 包含 tmpfs 时必须从一开始就使用 `sudo`。卸载会移除目标 backend 的安装文件、旧配置清理产物与日志，但不会自动卸载挂载点，也不会自动 eject 卷。

需要时手动执行：

```sh
umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
