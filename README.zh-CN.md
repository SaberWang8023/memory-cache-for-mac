# ramdisk-for-mac

[English README](README.md)

一个小型 macOS LaunchAgent 配置，用于在登录时自动创建 2 GB 的 APFS ramdisk。

默认挂载到：

```text
/Volumes/Ramdisk
```

同时会创建：

```text
/Volumes/Ramdisk/Cache/Chrome
```

## 安装

```sh
./install.sh
```

安装脚本会复制文件到：

```text
~/.local/bin/create_ram_disk.sh
~/Library/LaunchAgents/com.local.ramdisk.plist
```

日志会写入：

```text
~/Library/Logs/ramdisk.log
~/Library/Logs/ramdisk.err.log
```

## 卸载

```sh
./uninstall.sh
```

卸载脚本会移除已安装的脚本和 LaunchAgent。它不会自动卸载已经存在的 ramdisk。

## 自定义

安装前可以编辑 `src/create_ram_disk.sh`。

默认大小由下面这个变量控制：

```sh
SIZE_GB=2
```

默认卷名由下面这个变量控制：

```sh
DISK_NAME=Ramdisk
```

## 注意

Ramdisk 的内容保存在内存中。关机、重启、注销或卸载后，ramdisk 中的所有内容都会丢失。

这个项目适合用于缓存和临时文件，不适合存放需要持久保存的数据。
