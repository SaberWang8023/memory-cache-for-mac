# Remove Runtime Config Design

## Goal

Remove the runtime config file from `memory-cache-for-mac`.

The project now has only two supported installed shapes:

- `tmpfs` runs as a `LaunchDaemon`
- `apfs` runs as a `LaunchAgent`

Because backend and service mode are already fixed at install time, the runtime script does not need to discover or parse a config file on every launch.

## Non-Goals

- Do not add new backends.
- Do not keep user-editable runtime configuration.
- Do not split the runtime into two separate source scripts.
- Do not change the existing install commands beyond documenting that size changes require reinstalling.
- Do not make mount paths configurable.

## User-Facing Behavior

`install.sh` continues to support:

```sh
sudo ./install.sh --backend tmpfs
./install.sh --backend apfs
./install.sh --size 1g
sudo ./install.sh --backend tmpfs --size 512m
```

`--backend` still selects the installed service mode:

- `tmpfs` installs the daemon path and requires sudo.
- `apfs` installs the agent path and does not require sudo.

`--size` is an install-time value. To change cache size later, the user reruns `install.sh` with the desired backend and size. The installer overwrites the installed runtime script and service plist for that mode.

The installer no longer creates a config file. New installs no longer mention a config path.

## Runtime Constants

The installed runtime script contains the values chosen by the installer:

```sh
BACKEND=tmpfs|apfs
CACHE_SIZE=512m|1g|2g|...
SERVICE_MODE=daemon|agent
TARGET_USER=<resolved user>
TARGET_HOME=<resolved home>
```

The runtime derives the remaining values from those constants:

```sh
TMPFS_MOUNT_PATH="$TARGET_HOME/tmpfs"
APFS_DISK_NAME=Ramdisk
APFS_MOUNT_PATH=/Volumes/Ramdisk
CREATE_DIRS="Downloads Cache/Chrome Cache/Music"
```

These derived values are no longer configurable.

## Installation Flow

`install.sh` remains the only place that chooses backend, service mode, target user, target home, and cache size.

After validating those values, `install.sh` installs `src/create_memory_cache.sh` with an injected constants block near the top of the installed copy. The source script in `src/` remains the single maintained runtime implementation.

The installed copy must be runnable without any external project state except the macOS commands it already uses.

## Runtime Flow

`src/create_memory_cache.sh` stops doing config discovery and loading.

Remove:

- `runtime_daemon_config_path`
- `resolve_default_config_path`
- `load_config_from`
- `load_config`
- `require_config_var`
- `MEMORY_CACHE_CONFIG_PATH`

Keep validation that still protects real behavior:

- `BACKEND` must be `tmpfs` or `apfs`.
- `SERVICE_MODE` must be `daemon` or `agent`.
- `CACHE_SIZE` must normalize successfully.
- `APFS_DISK_NAME` validation may remain, but with the fixed value it becomes a defensive check rather than user-facing configuration.

The runtime still fails instead of falling back when the selected backend cannot mount.

## Uninstall And Migration

`uninstall.sh` must continue deleting old config paths:

- `/Library/Application Support/memory-cache-for-mac/config`
- `~/.config/memory-cache-for-mac/config`

This is migration cleanup for installations created before this change.

Switching backend during install must also keep removing old config paths when cleaning the opposite mode.

## Documentation Changes

README files must remove the configuration section and replace it with a smaller rule:

- cache size is chosen during install
- rerun `install.sh --backend ... --size ...` to change it
- mount paths and default directories are fixed

Installed artifact lists must no longer include config files.

## Tests

Update install tests to assert no config file is created.

Keep coverage for:

- tmpfs installs still write daemon artifacts
- apfs installs still write agent artifacts
- explicit `--size` is embedded in the installed runtime
- switching backend removes old config files
- invalid size still fails during install

Update runtime tests to execute installed or patched runtime scripts with embedded constants instead of writing config files for every case.

Keep one focused runtime test for invalid embedded constants so the defensive validation is covered.

## Acceptance Criteria

- A fresh `tmpfs` install creates no config file and the installed daemon runtime uses the selected size.
- A fresh `apfs` install creates no config file and the installed agent runtime uses the selected size.
- Running the source runtime without injected constants fails clearly.
- Old config files are still removed during uninstall and backend switching.
- README and README.zh-CN no longer tell users to edit config.
