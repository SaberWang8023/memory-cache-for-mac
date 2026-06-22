# 基于后端自动选择服务模式的设计

## 摘要

将 `memory-cache-for-mac` 从当前单一的 `LaunchAgent` 安装模型演进为“由 backend 决定服务模式”的安装模型：

- `tmpfs` 安装并运行在系统级 `LaunchDaemon`
- `apfs` 安装并运行在用户级 `LaunchAgent`

安装器根据用户选择的 backend 自动决定服务模式。切换 backend 时，安装器会先移除上一种模式对应的已安装产物，再安装新的模式。运行时 backend 逻辑仍然保持为一份共享脚本。

这个设计保留当前已经验证可用的 `apfs` 路径，同时让 `tmpfs` 可以在需要 root 权限的 macOS 环境中工作。

## 背景与动机

在当前这台机器上的手动验证已经确认了以下事实：

- `mount_tmpfs` 存在，并且系统支持 `tmpfs`
- 在普通用户上下文中直接调用 `mount_tmpfs` 会报 `Operation not permitted`
- 使用 `sudo mount_tmpfs ...` 可以成功挂载
- 一旦由 root 完成挂载，运行时脚本能够正确识别“已经挂载”，并继续创建默认子目录

这说明当前仅依赖 `LaunchAgent` 的模型，对于 `tmpfs` 来说在至少一部分支持的 macOS 系统上是不够的。另一方面，`apfs` 在用户级 agent 模型下仍然可以正常工作。因此，项目应当让服务模式适配 backend 的权限需求，而不是强行让两个 backend 共用同一种服务模型。

## 目标

- 保持 `tmpfs` 和 `apfs` 作为唯一支持的 backend
- 根据 backend 自动选择服务模式
- 对 `tmpfs` 明确要求 `sudo` 安装，因为它需要安装 `LaunchDaemon` 并以 root 执行 `mount_tmpfs`
- 保留 `apfs` 的用户级安装方式
- 在切换 backend 时自动清理上一种服务模式对应的安装产物
- 保持一份共享的运行时脚本，统一负责挂载和目录创建
- 运行时不在 backend 之间做静默 fallback
- 保持项目当前“卸载行为保守”的原则，不主动卸载挂载点，也不主动删除用户数据根目录

## 非目标

- 不引入独立的特权 helper、XPC 服务、`SMJobBless` 或 GUI 安装流
- 不把两个 backend 都统一迁移到 `LaunchDaemon`
- 不在安装、重装、切换 backend 或卸载时自动 `umount tmpfs` 或自动 eject APFS ramdisk
- 不支持 `/Volumes/$APFS_DISK_NAME` 之外的任意 APFS 挂载路径
- 不增加新的 backend

## 服务模型

### Backend 与服务模式映射

- `tmpfs` -> `LaunchDaemon`
- `apfs` -> `LaunchAgent`

这个映射关系是固定的，并且完全由 `BACKEND` 决定。

### 共享运行时

项目继续使用同一个运行时入口脚本，即 [src/create_memory_cache.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/src/create_memory_cache.sh)。

运行时脚本继续负责：

- 读取配置
- 校验 backend 对应配置
- 挂载 `tmpfs` 或 APFS ramdisk
- 创建配置中的默认子目录
- 在 backend 创建失败时输出清晰错误

运行时脚本本身不负责决定“当前应该作为 daemon 运行还是 agent 运行”。这个决定由安装器在安装阶段完成，并通过不同的配置文件位置、plist 位置和运行身份体现出来。

### 服务安装层

[install.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/install.sh) 和 [uninstall.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/uninstall.sh) 负责：

- 根据 backend 选择服务模式
- 安装到用户路径或系统路径
- bootstrap 对应的 `launchd` domain
- 在切换 backend 时移除另一种模式留下的安装产物

## 配置模型

### 逻辑配置

运行时配置继续描述 cache 本身的逻辑属性：

- `BACKEND`
- `CACHE_SIZE`
- `CREATE_DIRS`
- `APFS_DISK_NAME`
- `APFS_MOUNT_PATH`
- `TMPFS_MOUNT_PATH`

### 安装上下文

安装后的配置还必须显式记录安装上下文，这样运行时脚本就不需要依赖当前进程环境中的 `$HOME`、当前用户等隐式信息：

- `SERVICE_MODE=agent|daemon`
- `TARGET_USER=<登录短用户名>`
- `TARGET_HOME=/Users/<登录短用户名>`

`TARGET_USER` 与 `TARGET_HOME` 在两种模式下都必须存在，这样运行时脚本可以有一份稳定一致的契约。

本文中的尖括号值是“示意性的最终取值”，不是遗留待定项。

### 路径规则

在这个设计下，运行时不应再用 `$HOME` 推导关键路径。

必须满足的路径行为：

- `tmpfs` 默认挂载路径：`/Users/<TARGET_USER>/tmpfs`
- `apfs` 默认挂载路径：`/Volumes/<APFS_DISK_NAME>`
- `apfs` 的挂载路径仍然必须严格等于 `/Volumes/$APFS_DISK_NAME`

安装后的配置文件路径：

- `apfs` / agent 配置：`~/.config/memory-cache-for-mac/config`
- `tmpfs` / daemon 配置：`/Library/Application Support/memory-cache-for-mac/config`

安装后的运行时脚本路径：

- `apfs` / agent 脚本：`~/.local/bin/create_memory_cache.sh`
- `tmpfs` / daemon 脚本：`/usr/local/libexec/create_memory_cache.sh`

安装后的 plist 路径：

- `apfs` / agent plist：`~/Library/LaunchAgents/com.local.memory-cache.plist`
- `tmpfs` / daemon plist：`/Library/LaunchDaemons/com.local.memory-cache.plist`

安装后的日志路径：

- `apfs` / agent 日志：`~/Library/Logs/memory-cache.log` 和 `~/Library/Logs/memory-cache.err.log`
- `tmpfs` / daemon 日志：`/Library/Logs/memory-cache.log` 和 `/Library/Logs/memory-cache.err.log`

## 权限模型

### tmpfs

`tmpfs` 安装要求 root 权限，原因有三点：

- `mount_tmpfs` 在当前验证过的系统上需要提权
- 该 backend 安装为系统级 daemon
- 对应安装产物写入系统路径

支持的安装命令形态为：

```sh
sudo ./install.sh --backend tmpfs
```

如果用户在没有有效 root 权限的情况下请求安装 `tmpfs`，安装器必须在做出任何部分变更之前直接失败，并输出清晰错误：

```text
tmpfs backend requires sudo because it installs a LaunchDaemon and mounts tmpfs as root
```

在 `tmpfs` 挂载成功后，运行时脚本必须确保挂载根目录以及创建出的默认子目录对 `TARGET_USER` 可写。也就是说，脚本需要在挂载后补上目录所有权和权限调整，避免用户得到一个挂上了但自己无法正常使用的 cache 目录。

### apfs

`apfs` 继续保持用户级安装路径，正常使用时不要求 root：

```sh
./install.sh --backend apfs
```

如果用户用 `sudo` 运行 `apfs` 安装，安装器也必须仍然把目标用户解析为“原始调用者”而不是 root，并把安装产物写入该用户的 home，而不是误装进 `/var/root`。如果无法安全判断原始用户，安装必须失败，并提示清晰错误，而不是继续安装到错误位置。

## 安装行为

### Backend 选择

backend 选择行为沿用当前项目的基本规则：

- 当 `mount_tmpfs` 可用时，推荐 `tmpfs`
- 仍然支持显式传入 `--backend tmpfs|apfs`
- backend 和 size 的校验规则维持现有行为

### tmpfs 安装

`tmpfs` 安装必须：

- 要求有效 root 权限
- 清理当前项目已有的 agent 模式安装
- 写入 daemon 模式的脚本、配置和 plist
- bootstrap `system/com.local.memory-cache`
- kickstart `system/com.local.memory-cache`

### apfs 安装

`apfs` 安装必须：

- 清理当前项目已有的 daemon 模式安装
- 写入 agent 模式的脚本、配置和 plist
- bootstrap `gui/<target_uid>/com.local.memory-cache`
- kickstart `gui/<target_uid>/com.local.memory-cache`

### 切换 backend 时的清理规则

切换 backend 时，安装器必须在安装目标模式之前，自动移除另一种模式留下的安装产物。

切换到 `tmpfs` 时，移除：

- 用户 plist
- 用户安装的运行时脚本
- 用户配置文件
- 当前项目的用户日志
- 如果仍然存在，旧的 `com.local.ramdisk` 用户级产物

切换到 `apfs` 时，移除：

- 系统 plist
- 系统安装的运行时脚本
- daemon 配置文件
- 当前项目的 daemon 日志

整个清理顺序应当尽量避免半安装状态：

1. 先 boot out 旧服务
2. 删除旧服务的安装文件
3. 写入新配置和新文件
4. bootstrap 新服务
5. kickstart 新服务

如果旧模式清理失败，安装器必须停止，而不是带着混合状态继续安装。

## 卸载行为

[uninstall.sh](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/uninstall.sh) 需要能够探测并清理任意一种服务模式，同时继续处理旧标签 `com.local.ramdisk` 的遗留产物。

卸载行为要求：

- 如果存在，移除用户模式安装
- 如果存在，移除 daemon 模式安装
- 如果存在，移除旧的 `com.local.ramdisk` 用户模式产物
- 在删除 plist 文件之前，先 boot out 对应的 `launchd` domain

daemon 模式产物的移除需要 root 权限。如果系统中存在 daemon 安装，但当前卸载命令没有足够权限，脚本必须直接失败，并明确提示 daemon 卸载需要 `sudo`。

卸载仍然保持保守原则：

- 不自动 `umount ~/tmpfs`
- 不自动 eject `/Volumes/Ramdisk`
- 不自动删除 `~/tmpfs`
- 不自动删除 `/Volumes/Ramdisk`
- 不自动删除挂载根目录中由用户创建的内容

卸载器的职责只限于清理由本项目安装出来的脚本、plist、配置和日志。

## 运行时行为

### tmpfs 运行时

`tmpfs` 运行时继续保留当前这些行为：

- 校验配置
- 拒绝挂载到非空的普通目录
- 使用 `mount_tmpfs -i -s "$CACHE_SIZE" "$TMPFS_MOUNT_PATH"` 进行挂载
- 挂载后创建配置中的默认子目录

新增要求：

- 挂载成功后，需要把挂载根目录和子目录的所有权与权限调整为 `TARGET_USER` 可写

如果路径已经处于已挂载状态，运行时应当：

- 确保默认子目录存在
- 确保目录所有权符合预期
- 成功退出

### apfs 运行时

`apfs` 运行时保持现有行为：

- 校验 disk name
- attach ramdisk
- partition APFS
- 要求 APFS 卷最终出现在 `/Volumes/$APFS_DISK_NAME`
- 创建默认子目录

运行时不增加“失败后自动切到 `tmpfs`”的逻辑。

## Plist 模板

项目应维护两份 plist 模板：

- 一份用于 `LaunchAgent`
- 一份用于 `LaunchDaemon`

两者可以共用同一个 label，也可以共用同一个安装后脚本名，但必须在以下方面有所区分：

- 安装路径
- 日志路径
- bootstrap domain
- 用户模式与系统模式的运行上下文

daemon 的 plist 应通过放置在 `/Library/LaunchDaemons` 中而以 root 身份运行，不应显式设置 `UserName=<target_user>`，否则会重新把 `mount_tmpfs` 拉回普通用户权限，从而再次触发当前已经验证过的权限问题。

## 目标用户解析

虽然 `tmpfs` 以 daemon 方式运行，但它仍然服务于一个明确的用户路径，因此安装器必须显式解析目标登录用户。

要求如下：

- 非 `sudo` 安装时，直接使用当前用户
- `sudo` 安装时，优先解析原始调用者，而不是 root
- 如果无法将目标用户解析为一个位于 `/Users` 下、拥有有效 home 目录的非 root 用户，则必须拒绝安装

安装后的配置中必须写入解析后的 `TARGET_USER` 和 `TARGET_HOME`。

## 文档更新

[README.md](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/README.md) 和 [README.zh-CN.md](/Users/saber/Workspace/OpenSource/memory-cache-for-mac/README.zh-CN.md) 需要更新，明确说明：

- backend 与服务模式的自动映射关系
- `tmpfs` 需要使用 `sudo ./install.sh --backend tmpfs`
- `apfs` 继续保持用户级安装
- agent 与 daemon 两种模式下安装文件路径不同
- agent 与 daemon 两种模式下日志路径不同
- 切换 backend 时会自动清理另一种模式的安装产物
- 卸载仍然不会自动卸载挂载点或 eject 卷

项目对外描述也不应继续只写成“一个 LaunchAgent 配置”。

## 测试策略

测试仍然以 shell 测试为主，但需要扩展为三个层面。

### 安装器测试

新增测试应覆盖：

- `apfs` 安装会写入用户模式路径
- `tmpfs` 安装会写入 daemon 模式路径
- `tmpfs` 在无 root 权限时安装失败
- 从 `apfs` 切换到 `tmpfs` 时会删除 agent 模式产物
- 从 `tmpfs` 切换到 `apfs` 时会删除 daemon 模式产物
- 用 `sudo` 触发 `apfs` 安装时，目标用户仍然是原始用户而不是 root

### 运行时测试

保留当前已有的配置校验、非空目录拒绝、APFS 路径校验等测试，并新增覆盖：

- `SERVICE_MODE`、`TARGET_USER`、`TARGET_HOME` 为必填项
- daemon 模式下 `tmpfs` 使用绝对用户路径
- `tmpfs` 成功挂载后的所有权调整行为
- 已挂载的 `tmpfs` 场景下，目录创建与所有权修正行为

### 手动集成验证

手动验证需要覆盖真实 macOS 机器上的两条 backend 路径。

`tmpfs`：

```sh
sudo ./install.sh --backend tmpfs --size 1g
mount | grep -F " on /Users/<target_user>/tmpfs "
find "/Users/<target_user>/tmpfs" -maxdepth 3 -type d | sort
```

`apfs`：

```sh
./install.sh --backend apfs --size 1g
mount | grep -F " on /Volumes/Ramdisk "
find /Volumes/Ramdisk -maxdepth 3 -type d | sort
```

切换验证还应确认：backend 切换只会移除安装产物，不会主动卸载已经存在的 cache 挂载根。

## 验收标准

- 不带 `sudo` 安装 `tmpfs` 时，安装器会在部分安装发生之前直接失败，并输出清晰错误
- 使用 `sudo` 安装 `tmpfs` 后，会得到可工作的 daemon 模式安装，并在 `/Users/<target_user>/tmpfs` 创建 cache
- 安装 `apfs` 后，会在目标用户的 home 下得到可工作的 agent 模式安装
- 切换 backend 时，安装器会先移除上一种模式的安装产物，再激活新的模式
- 运行时继续拒绝非空普通目录和非法 APFS 挂载配置
- 卸载会移除任意模式下的安装产物，但不会自动碰挂载根目录
- 文档清楚说明服务模式选择、权限要求、安装路径和清理行为
