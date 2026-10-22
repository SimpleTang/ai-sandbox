# 更新日志

本项目遵循[语义化版本](https://semver.org/lang/zh-CN/)。1.0 之前，次版本号的变化可能包含不兼容的改动，升级前请先看对应版本的「升级须知」。

`aibox --version` 显示当前安装的版本。

## [0.1.0] - 2026-10-22

首个带版本号的发布。新增安装向导；默认的 `aibox` 改为长期容器，原来的一次性容器改用 `aibox tmp`；两种容器的 Claude / Codex 登录状态统一到 `~/.aibox/`。

English summary: first versioned release. Adds a setup wizard (`./setup.sh` / `aibox setup`), makes the persistent container the default (`aibox`, `aibox cc`), moves throwaway containers to `aibox tmp`, and unifies Claude/Codex state under `~/.aibox/` with a guided migration. Verified on Apple container 1.6.0. See the upgrade notes before updating an existing install.

### 升级须知（从没有版本号的旧版升级）

- **命令有变化**：

  | 旧命令 | 新命令 |
  |---|---|
  | `aibox dev`、`aibox dev cc` … | `aibox`、`aibox cc` … |
  | `aibox dev start / stop / update / status …` | `aibox start / stop / update / status …` |
  | `aibox`、`aibox cc`（一次性容器） | `aibox tmp`、`aibox tmp cc` |
  | `aibox list / enter / stop <目标> / logs / clear` | `aibox tmp list / enter / stop <目标> / logs / clear` |
  | `aibox start`（启动 container 服务） | 进入长期容器的命令会自动启动服务；也可以直接运行 `container system start` |

  `aibox dev` 已经移除，执行旧写法会提示对应的新命令。
- **登录状态会迁移**：旧版临时容器的状态在仓库 `creds/`，长期容器的在机内 `/home/<用户>/.claude`、`.codex`。新版首次启动时会检测这些旧数据：两边都有时让你选用长期容器的、临时容器的，或者合并。旧数据不会被删除，机内旧目录会改名备份并换成指向 `~/.aibox` 的软链接，`creds/` 挪到 `~/.aibox/legacy/`。详见 README「认证」一节。
- **迁移前先退出所有正在运行的 Claude Code / Codex 会话**，包括长期容器里的。迁移之后，仍在运行的旧会话写入的内容不会出现在 `~/.aibox` 里。
- **镜像**：从 2026-08 的「新增持久开发机与剪贴板图片桥接」（`c33c6c6`）之后的版本升级，不需要重建镜像，已有的长期容器会在启动时自动同步新的辅助脚本。更早的版本请运行 `aibox build`。
- **Apple container**：已在 1.6.0 上验证，最低要求 1.0.0。升级方法见 README「安装 Apple container」。

### 新增

- 安装向导：刚克隆时运行 `./setup.sh`，之后随时 `aibox setup` 重跑，`--check` 只检查不修改。依次完成环境检查、安装 Apple container（可自动下载官方安装包并核对 Apple 签名）、启动服务、安装命令与补全、生成 `aibox.conf`、迁移旧版数据、构建镜像、启用剪贴板贴图；已完成的步骤自动跳过。
- 生成 `aibox.conf` 时校验代理地址，把 `127.0.0.1` 这类容器内不可达的地址换成宿主机在容器网络中的地址；可自动下载 gost 并校验 SHA-256，可测试代理连通性；API key 输入不回显。
- `aibox tmp ...`：一次性容器的全部命令。
- `aibox migrate`：手动触发旧版数据迁移。
- `aibox --version`：显示 aibox 自身的版本。
- `aibox status` 显示 aibox 版本、Apple container 的已装版本与已验证版本，以及长期容器和临时容器的状态。
- 一次性容器的镜像还没构建时提前报错，并提示运行 `aibox build` 或 `aibox setup`，不再去 Docker Hub 拉同名镜像。

### 变更

- 默认模式改为长期容器：`aibox [路径]`、`aibox cc`、`aibox codex` 在指定目录（须在宿主 Home 内）进入长期容器；container 服务未启动时自动启动。
- Claude / Codex 的登录状态与配置统一到宿主机的 `~/.aibox/claude`、`~/.aibox/codex`，两种容器共用，与 Mac 本机的 `~/.claude`、`~/.codex` 分开。
- `aibox build` 依次构建基础镜像和长期容器镜像；`aibox tmp build` 只构建基础镜像。
- `aibox update` 与 `aibox tmp update` 统一为先列出「当前版本 -> 最新版本」，确认后才安装。
- 长期容器每次启动时同步仓库里的辅助脚本和 `third_party/gost`，已有的长期容器不用重建就能用上新行为。
- 安装向导改为下载已验证版本的 Apple container，不再取最新版。

### 修复

- `aibox exec` 的参数带空格或引号时会被拆开（Apple container 的 `machine run` 会把参数拼成一行重新解析）。
- 新建长期容器后第一次运行偶发 `Inappropriate ioctl for device`，现在会自动重试。
- 迁移时机内目录里的 Unix socket 导致复制失败，现在会跳过 socket。
- 自定义的 `PATH` 不含 `/bin` 时，长期容器登录失败。
- macOS 自带 Bash 3.2 下，变量后紧跟中文时被误读为变量名的一部分。
- 冒烟测试受运行环境影响（Linux 上缺少 `plutil`、macOS `TMPDIR` 结尾的 `/`、本机的剪贴板桥接与环境变量），CI 恢复通过。
