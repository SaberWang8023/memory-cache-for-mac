# ramdisk-for-mac

[中文说明](README.zh-CN.md)

A small macOS LaunchAgent setup that creates a 2 GB APFS ramdisk at login.

By default it mounts:

```text
/Volumes/Ramdisk
```

It also creates:

```text
/Volumes/Ramdisk/Cache/Chrome
```

## Install

```sh
./install.sh
```

The installer copies files to:

```text
~/.local/bin/create_ram_disk.sh
~/Library/LaunchAgents/com.local.ramdisk.plist
```

Logs are written to:

```text
~/Library/Logs/ramdisk.log
~/Library/Logs/ramdisk.err.log
```

## Uninstall

```sh
./uninstall.sh
```

Uninstalling removes the installed script and LaunchAgent. It does not unmount
an existing ramdisk.

## Customize

Edit `src/create_ram_disk.sh` before installing.

The default size is controlled by:

```sh
SIZE_GB=2
```

The default volume name is controlled by:

```sh
DISK_NAME=Ramdisk
```

## Notes

Ramdisk contents are stored in memory. Everything on the ramdisk is lost after
shutdown, restart, logout, or unmounting.

This project is intended for cache and temporary files, not persistent data.
