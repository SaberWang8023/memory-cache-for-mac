# Backend-Based Service Mode Design

## Summary

Evolve `memory-cache-for-mac` from a single `LaunchAgent`-only install model into a backend-aware install model:

- `tmpfs` installs and runs as a system `LaunchDaemon`
- `apfs` installs and runs as a user `LaunchAgent`

The installer automatically selects the service mode from the chosen backend. Switching backends automatically removes the installed artifacts for the previous mode before installing the new one. Runtime backend logic remains in one shared script.

This design preserves the current working `apfs` path while making `tmpfs` usable on systems where `mount_tmpfs` requires root privileges.

## Motivation

Manual verification on this machine established the following facts:

- `mount_tmpfs` exists and can mount `tmpfs`
- a direct user-context invocation of `mount_tmpfs` fails with `Operation not permitted`
- a `sudo mount_tmpfs ...` invocation succeeds
- once mounted by root, the runtime script correctly detects the existing mount and creates child directories

That means the current `LaunchAgent` model is insufficient for `tmpfs` on at least some supported macOS installations. `apfs` continues to work in a user agent context, so the project should adapt service mode to backend requirements instead of forcing one service model onto both backends.

## Goals

- Keep `tmpfs` and `apfs` as the only supported backends.
- Select service mode automatically from backend choice.
- Require `sudo` for `tmpfs` installation because it installs a `LaunchDaemon` and mounts `tmpfs` as root.
- Preserve user-level installation for `apfs`.
- Automatically remove the previously installed service mode when switching backends.
- Keep a single shared runtime script for backend mounting and directory creation.
- Avoid automatic fallback between backends at runtime.
- Preserve the project's conservative uninstall behavior for mounted cache roots and existing data.

## Non-Goals

- Do not introduce a privileged helper app, XPC service, `SMJobBless`, or GUI installer flow.
- Do not make both backends run as `LaunchDaemon`.
- Do not automatically unmount `tmpfs` or eject APFS ramdisks during install, reinstall, backend switching, or uninstall.
- Do not support arbitrary APFS mount paths beyond `/Volumes/$APFS_DISK_NAME`.
- Do not add new backends.

## Service Model

### Backend To Service Mode Mapping

- `tmpfs` -> `LaunchDaemon`
- `apfs` -> `LaunchAgent`

This mapping is fixed and determined entirely by `BACKEND`.

### Shared Runtime

The project continues to use one runtime entrypoint, `src/create_memory_cache.sh`.

The runtime script remains responsible for:

- loading config
- validating backend-specific configuration
- mounting `tmpfs` or APFS ramdisk
- creating configured child directories
- emitting clear errors when the configured backend cannot be created

The runtime script does not decide whether it should behave as a daemon or agent. That choice is made during installation by the installer and reflected through the installed config and plist location.

### Service Installation Layer

`install.sh` and `uninstall.sh` become responsible for:

- determining the service mode from backend
- installing to user or system locations
- bootstrapping the correct `launchd` domain
- removing old artifacts from the opposite service mode during backend switches

## Configuration Model

### Logical Configuration

The runtime config continues to describe the cache itself:

- `BACKEND`
- `CACHE_SIZE`
- `CREATE_DIRS`
- `APFS_DISK_NAME`
- `APFS_MOUNT_PATH`
- `TMPFS_MOUNT_PATH`

### Installation Context

The installed config must also describe the resolved install context so the runtime script does not depend on ambient environment:

- `SERVICE_MODE=agent|daemon`
- `TARGET_USER=<short login name>`
- `TARGET_HOME=/Users/<short login name>`

`TARGET_USER` and `TARGET_HOME` are required in both modes so the runtime script has one consistent contract.

Angle-bracket values in this document are illustrative resolved values, not placeholders left for later product decisions.

### Path Rules

The runtime must not rely on `$HOME` for important paths after this change.

Required path behavior:

- `tmpfs` default mount path: `/Users/<TARGET_USER>/tmpfs`
- `apfs` default mount path: `/Volumes/<APFS_DISK_NAME>`
- `apfs` mount path must still equal `/Volumes/$APFS_DISK_NAME`

Installed config paths:

- `apfs` / agent config: `~/.config/memory-cache-for-mac/config`
- `tmpfs` / daemon config: `/Library/Application Support/memory-cache-for-mac/config`

Installed runtime script paths:

- `apfs` / agent script: `~/.local/bin/create_memory_cache.sh`
- `tmpfs` / daemon script: `/usr/local/libexec/create_memory_cache.sh`

Installed plist paths:

- `apfs` / agent plist: `~/Library/LaunchAgents/com.local.memory-cache.plist`
- `tmpfs` / daemon plist: `/Library/LaunchDaemons/com.local.memory-cache.plist`

Installed log paths:

- `apfs` / agent logs: `~/Library/Logs/memory-cache.log` and `~/Library/Logs/memory-cache.err.log`
- `tmpfs` / daemon logs: `/Library/Logs/memory-cache.log` and `/Library/Logs/memory-cache.err.log`

## Permissions Model

### tmpfs

`tmpfs` installation requires root because:

- `mount_tmpfs` needs elevated privileges on supported systems like the one verified here
- the service is installed as a system daemon
- artifacts are written into system-owned paths

The supported installation command is:

```sh
sudo ./install.sh --backend tmpfs
```

If `tmpfs` is requested without effective root privileges, the installer must fail before making partial changes and print a direct message:

```text
tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root
```

After a successful `tmpfs` mount, the runtime script must ensure the mount root and created child directories are writable by `TARGET_USER`. The script should adjust ownership after mount creation so the user can actually use the cache directory.

### apfs

`apfs` remains a user installation path and does not require root when used normally:

```sh
./install.sh --backend apfs
```

If the installer is invoked with `sudo` for `apfs`, it must still resolve the intended target user and install into that user account's paths rather than `/var/root`. If the original invoking user cannot be determined safely, installation must fail with a clear error instead of installing into the wrong home directory.

## Install Behavior

### Backend Selection

The existing backend selection behavior remains:

- recommend `tmpfs` when `mount_tmpfs` exists
- allow explicit `--backend tmpfs|apfs`
- validate backend values and size values exactly as today

### tmpfs Install

`tmpfs` install must:

- require effective root privileges
- remove any existing agent-mode installation for this project
- install daemon-mode script, config, and plist
- bootstrap `system/com.local.memory-cache`
- kickstart `system/com.local.memory-cache`

### apfs Install

`apfs` install must:

- remove any existing daemon-mode installation for this project
- install agent-mode script, config, and plist
- bootstrap `gui/<target_uid>/com.local.memory-cache`
- kickstart `gui/<target_uid>/com.local.memory-cache`

### Backend Switch Cleanup

Switching backends must automatically remove artifacts from the opposite mode before installing the target mode.

When switching to `tmpfs`, remove:

- user plist
- user installed runtime script
- user config
- user logs for this project
- old `com.local.ramdisk` user artifacts if still present

When switching to `apfs`, remove:

- system plist
- system installed runtime script
- daemon config
- daemon logs for this project

The cleanup sequence should avoid half-installed states:

1. boot out the previous service if present
2. remove its installed files
3. write new config and files
4. bootstrap the new service
5. kickstart the new service

If cleanup of the previous mode fails, installation must stop rather than continuing with a mixed state.

## Uninstall Behavior

`uninstall.sh` must detect and remove either service mode, plus any leftover old-label artifacts.

Behavior requirements:

- remove user-mode installation if present
- remove daemon-mode installation if present
- remove old `com.local.ramdisk` user-mode artifacts if present
- boot out the matching `launchd` domain before deleting plist files

Daemon artifact removal requires root privileges. If daemon installation is present and uninstall is not running with sufficient privileges, the script must fail with a clear message explaining that daemon uninstall requires `sudo`.

Uninstall remains conservative:

- do not `umount ~/tmpfs`
- do not eject `/Volumes/Ramdisk`
- do not delete `~/tmpfs`
- do not delete `/Volumes/Ramdisk`
- do not remove user-created contents inside mounted cache roots

The uninstaller's responsibility is limited to installed service/config/script/log artifacts.

## Runtime Behavior

### tmpfs Runtime

`tmpfs` runtime continues to:

- validate config
- refuse to mount over a non-empty ordinary directory
- mount with `mount_tmpfs -i -s "$CACHE_SIZE" "$TMPFS_MOUNT_PATH"`
- create configured child directories after mount

New requirement:

- after mounting, adjust ownership and permissions so `TARGET_USER` can write to the mount root and child directories

If the path is already mounted, runtime should:

- ensure child directories exist
- ensure expected user ownership is correct
- exit successfully

### apfs Runtime

`apfs` runtime keeps its current behavior:

- validate disk name
- attach ramdisk
- partition APFS
- require the APFS volume to appear at `/Volumes/$APFS_DISK_NAME`
- create configured child directories

No runtime fallback to `tmpfs` is added.

## Plist Templates

The project should maintain separate plist templates:

- one for `LaunchAgent`
- one for `LaunchDaemon`

They can share the same label and installed runtime script name but must differ in:

- installation path
- log path
- bootstrap domain
- user-vs-system expectations

The daemon plist should run as root by virtue of residing in `/Library/LaunchDaemons`; it should not set `UserName` to the target user, because doing so would reintroduce the permission problem for `mount_tmpfs`.

## Target User Resolution

Because `tmpfs` daemon mode still serves a specific user path, the installer must resolve the target login user explicitly.

Required behavior:

- when installing without `sudo`, use the current user
- when installing with `sudo`, prefer the original invoking user rather than root
- reject installs where the target user cannot be resolved to a non-root account with a home directory under `/Users`

The installed config must contain the resolved `TARGET_USER` and `TARGET_HOME`.

## Documentation Updates

`README.md` and `README.zh-CN.md` must be updated to reflect:

- backend-based service mode selection
- `tmpfs` requiring `sudo ./install.sh --backend tmpfs`
- `apfs` remaining a user-level install
- different installed file paths for agent and daemon modes
- different log locations for agent and daemon modes
- automatic cleanup when switching backends
- the continued rule that uninstall does not unmount or eject cache roots

The project description should no longer describe itself only as a `LaunchAgent` setup.

## Testing Strategy

The test suite remains shell-based and expands in three areas.

### Installer Tests

Add tests that verify:

- `apfs` install writes user-mode paths
- `tmpfs` install writes daemon-mode paths
- `tmpfs` install fails without root privileges
- switching from `apfs` to `tmpfs` removes agent-mode artifacts
- switching from `tmpfs` to `apfs` removes daemon-mode artifacts
- invoking `apfs` install under `sudo` still targets the original user, not root

### Runtime Tests

Keep current validation tests and add coverage for:

- required `SERVICE_MODE`, `TARGET_USER`, and `TARGET_HOME`
- daemon-mode `tmpfs` path resolution using absolute user paths
- ownership-adjustment behavior after successful `tmpfs` mount
- already-mounted `tmpfs` ensuring directory creation and user ownership

### Manual Verification

Manual verification should include both backend paths on a real macOS machine.

`tmpfs`:

```sh
sudo ./install.sh --backend tmpfs --size 1g
mount | grep -F " on /Users/<target_user>/tmpfs "
find "/Users/<target_user>/tmpfs" -maxdepth 3 -type d | sort
```

`apfs`:

```sh
./install.sh --backend apfs --size 1g
mount | grep -F " on /Volumes/Ramdisk "
find /Volumes/Ramdisk -maxdepth 3 -type d | sort
```

Switch verification should also confirm that changing backend removes only installed artifacts and does not unmount existing cache roots.

## Acceptance Criteria

- Installing `tmpfs` without `sudo` fails with a clear error before partial installation.
- Installing `tmpfs` with `sudo` produces a working daemon-mode installation and mounts cache at `/Users/<target_user>/tmpfs`.
- Installing `apfs` produces a working agent-mode installation under the target user's home directory.
- Switching backends automatically removes the previous mode's installed artifacts before activating the new mode.
- Runtime continues to refuse non-empty ordinary directories and invalid APFS mount configuration.
- Uninstall removes installed artifacts for either mode while leaving mounted cache roots untouched.
- Documentation clearly explains service-mode selection, privilege expectations, installed paths, and cleanup behavior.
