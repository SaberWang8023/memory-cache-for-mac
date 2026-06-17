# memory-cache-for-mac

[中文说明](README.zh-CN.md)

A small macOS LaunchAgent setup that creates a volatile in-memory cache space at login.

It uses `tmpfs` by default when `mount_tmpfs` is available, and still supports an APFS ramdisk backend for users who want a real APFS volume.

## Use Cases

- temporary downloads
- Chrome cache
- music application cache
- build or scratch cache

Do not use this for files that must survive logout, reboot, unmounting, or installation changes.

## Backends

| Backend | Default path | Best for | Notes |
| --- | --- | --- | --- |
| `tmpfs` | `~/tmpfs` | disposable cache directories | default when `mount_tmpfs` is available |
| `apfs` | `/Volumes/Ramdisk` | users who want a volume-like APFS ramdisk | optional compatibility backend |

The runtime does not silently fall back between backends. If the configured backend fails, it exits with an error.

## Capacity

The installer recommends a cache size from physical memory:

| Physical memory | Recommended size |
| --- | --- |
| `<= 16 GB` | `512m` |
| `> 16 GB` and `<= 48 GB` | `1g` |
| `> 48 GB` | `2g` |

This is only a recommendation. You can choose another size during install or edit the config later.

## Install

Interactive install:

```sh
./install.sh
```

Non-interactive examples:

```sh
./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
./install.sh --backend tmpfs --size 512m
```

Installed files:

```text
~/.local/bin/create_memory_cache.sh
~/Library/LaunchAgents/com.local.memory-cache.plist
~/Library/Logs/memory-cache.log
~/Library/Logs/memory-cache.err.log
~/.config/memory-cache-for-mac/config
```

Default directories under the cache root:

```text
Downloads
Cache/Chrome
Cache/Music
```

## Configuration

Edit:

```text
~/.config/memory-cache-for-mac/config
```

Example:

```sh
BACKEND=tmpfs
CACHE_SIZE=1g
TMPFS_MOUNT_PATH="$HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH="/Volumes/$APFS_DISK_NAME"
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
```

`TMPFS_MOUNT_PATH` is configurable. For the APFS backend, `APFS_MOUNT_PATH` must stay `/Volumes/$APFS_DISK_NAME`. To change the APFS mount location, change `APFS_DISK_NAME`, which changes the derived `/Volumes/<name>` path. Arbitrary APFS mount paths are not supported.

## Migration From ramdisk-for-mac

Installing this version stops and removes the old `com.local.ramdisk` LaunchAgent and `~/.local/bin/create_ram_disk.sh`.

It does not eject an existing `/Volumes/Ramdisk` volume. If you want to remove it after checking its contents:

```sh
diskutil eject /Volumes/Ramdisk
```

## Uninstall

```sh
./uninstall.sh
```

Uninstall removes installed files and config, but does not unmount or delete cache roots. Manual cleanup:

```sh
umount ~/tmpfs
diskutil eject /Volumes/Ramdisk
```
