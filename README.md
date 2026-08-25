# ai-sandbox

[中文](README.md) | [English](README.en.md)

在 Apple silicon Mac 上通过 [Apple container](https://github.com/apple/container) 运行 Claude Code 和 Codex CLI。默认模式每次创建一个只挂载当前项目及明确持久化目录的临时 Linux 容器；`aibox dev` 则提供一台挂载宿主 Home、系统盘长期保留的 Linux 开发机。

本项目是社区项目，与 Apple、Anthropic 或 OpenAI 无隶属或背书关系。Claude、Claude Code、OpenAI 和 Codex 等名称及商标归其各自权利人所有。使用相关服务时，请遵守对应条款和当地法律。

## 功能

- 一条 `aibox` 命令进入 shell，或直接启动 `claude` / `codex`。
- 每个终端会话使用独立的 `--rm` 容器，支持多个项目并行运行。
- `aibox dev` 创建或进入一台基于 `container machine` 的持久开发机，可在其中处理多个项目、安装长期保留的软件。
- 项目文件、Claude/Codex 登录状态及构建缓存按明确规则持久化。
- 默认直连；配置 gost 上游代理时启用 IPv4/IPv6 出口防火墙，禁止其他进程绕过代理直连。
- 时区和 locale 可跟随宿主机，也可逐次或通过配置文件指定。
- 镜像默认安装 `ai-ipcheck`，可直接使用 `ipcheck` 诊断容器网络环境。
- 提供容器列表、进入、停止、日志、状态、CLI 更新及 Tab 补全。
- `aibox clip install` 启用剪贴板图片桥接，沙箱内的 Claude Code 可用 Ctrl+V 直接粘贴宿主机剪贴板里的图片。
- `third_party/` 中的 gost、JDK 8 和 Maven 均为独立可选组件。

## 兼容性

| 项目 | 要求或当前配置 |
|---|---|
| 主机 | Apple silicon Mac |
| 操作系统 | macOS 26；Apple 官方不支持更旧版本 |
| 容器运行时 | [Apple container](https://github.com/apple/container)（已在 CLI 1.0.0 验证；不是 Docker） |
| 宿主脚本 | 兼容 macOS 自带 Bash 3.2；日常可从 zsh 调用 |
| 容器架构 | Linux ARM64，基础镜像为 `node:22-bookworm` |
| VM 内存 | 一次性容器和开发机默认均为 `8192M`；可在 `ai-box` 的 `MEMORY` / `DEV_MEMORY` 中调整 |

构建仍会联网下载基础镜像、APT/PyPI 包以及 Claude Code/Codex npm 包。`third_party/` 可为空并不表示镜像支持完全离线构建。

## 安装

### 1. 安装 Apple container

Apple container 是本项目的硬性前提，不是 Docker Desktop 的兼容别名。它由 Apple 使用 Swift 开发，在 Apple silicon Mac 上把 Linux 容器作为轻量虚拟机运行，并使用 OCI 兼容镜像。

- 官方仓库：[apple/container](https://github.com/apple/container)
- 官方安装包：[apple/container Releases](https://github.com/apple/container/releases)
- 硬件要求：Apple silicon；Intel Mac 不受支持。
- 系统要求：macOS 26；Apple 官方明确不支持更旧的 macOS，也通常不会处理无法在 macOS 26 复现的问题。

可以先确认机器满足要求：

```bash
uname -m                 # 应输出 arm64
sw_vers -productVersion  # 应为 26.x
```

按照 Apple 官方当前推荐方式安装：

1. 打开 [Releases 页面](https://github.com/apple/container/releases)，下载最新的 Apple 签名安装包。
2. 双击 `.pkg`，按安装器提示操作；系统会要求管理员密码，以便把文件安装到 `/usr/local`。
3. 启动 container 系统服务并验证 CLI：

```bash
container system start
container --version
container list
```

`container list` 即使没有运行中的容器也应能正常返回。安装完成后，后文的 `aibox start` 等价于再次执行 `container system start`。

已经安装旧版本时，Apple 提供的升级方式是先停止服务，再运行安装在 `/usr/local/bin` 下的更新脚本：

```bash
container system stop
/usr/local/bin/update-container.sh
container system start
```

具体安装、升级或卸载行为可能随 Apple container 版本变化，请以[官方仓库说明](https://github.com/apple/container#initial-install)为准。

### 2. 安装 ai-sandbox

克隆本仓库。仓库可以放在任意路径；`ai-box` 会根据脚本自身位置定位构建文件。

```bash
# 从 GitHub 页面克隆本仓库后，进入实际克隆目录
cd /absolute/path/to/ai-sandbox
chmod +x ai-box entrypoint.sh

mkdir -p "$HOME/.local/bin"
ln -sfn "$PWD/ai-box" "$HOME/.local/bin/aibox"
export PATH="$HOME/.local/bin:$PATH"
```

把最后一行加入 `~/.zshrc` 或 `~/.bashrc` 后可长期生效。也可以不创建软链，直接使用仓库中的 `./ai-box`。

可选的 Tab 补全：

```bash
# 将绝对路径写入 ~/.zshrc 或 ~/.bashrc，然后重新打开终端
source /absolute/path/to/ai-sandbox/ai-box-completion.sh
```

## 快速开始

无需代理或自定义区域设置时，不必创建配置文件：

```bash
aibox start
aibox build      # 构建一次性容器镜像

cd /path/to/your-project
aibox cc       # 启动 Claude Code
aibox codex    # 启动 Codex CLI
aibox          # 只进入 shell

# 或进入不绑定单个项目的持久开发机
aibox dev build  # 首次使用时构建开发机镜像
aibox dev
```

带 `cc` 或 `codex` 启动时，工具退出后会留在容器 shell；再次执行 `exit` 才会结束并删除该容器。项目文件及持久化目录中的变更不会随容器删除。

需要 API key、其他自定义环境变量、代理、固定时区或固定语言时：

```bash
cd /path/to/ai-sandbox
cp aibox.conf.example aibox.conf
chmod 600 aibox.conf
# 编辑 aibox.conf，然后重新运行 aibox；无需重建镜像
```

`aibox.conf` 可能包含 API key、代理凭据等秘密，已由 `.gitignore` 和 `.dockerignore` 排除，不要提交它，也不要把文件内容粘贴到 Issue 或日志中。

## 运行期配置

`aibox.conf` 是 Bash 配置片段：

```sh
AIBOX_PROXY=""  # 空值为直连；非空示例见 aibox.conf.example
AIBOX_TZ=""     # 空值跟随宿主机时区
AIBOX_LANG=""   # 空值跟随宿主机 LANG
AIBOX_ENV_VARS=( # 传入容器的自定义环境变量
  'EXAMPLE_NAME=value with spaces'
)
```

前三个标量配置的实际优先级与空值语义如下：

| 配置 | 优先级 |
|---|---|
| `AIBOX_PROXY` | 非空环境变量 > 非空 `aibox.conf` > 旧版 `FIXED_SOCKS_*` 兼容值（仅配置文件不存在时） > 直连 |
| `AIBOX_TZ` | 非空环境变量 > 非空 `aibox.conf` > 宿主机时区 > 镜像默认 `UTC` |
| `AIBOX_LANG` | 非空环境变量 > 非空 `aibox.conf` > 宿主机 `LANG` > 镜像默认 `C.UTF-8` |

例如 `AIBOX_TZ=UTC aibox` 只覆盖本次运行。脚本只把“非空环境变量”视为覆盖值，因此 `AIBOX_PROXY="" aibox` 不能清除配置文件中的非空代理；要切回直连，请把 `aibox.conf` 中的 `AIBOX_PROXY` 设为空。时区和语言同理，空值表示继续向后回退，而不是强制空值。

`AIBOX_LANG` 必须是镜像已生成的 locale。默认集合见 `Dockerfile` 的 `LOCALE_GEN`；加入其他 locale 后需重新运行 `aibox build`。

`AIBOX_ENV_VARS` 只从 `aibox.conf` 读取。它是在文件中声明的 Bash 数组，每项为一个完整的 `NAME=value`：

```bash
AIBOX_ENV_VARS=(
  'EMPTY_VALUE='
  'TEXT_VALUE=value with spaces'
  'ENDPOINT=https://example.invalid/path?a=b'
)
```

名称必须匹配 `[A-Za-z_][A-Za-z0-9_]*`，且不能以内部保留的 `AIBOX_` 开头。`ai-box` 按每项的第一个 `=` 拆分名称和值，因此值可以为空、包含空格或继续包含等号，但必须保持单行；包含回车（CR）或换行（LF）的值会被拒绝。数组遵循 Bash 的引号和展开语义：单引号内容按字面量读取，双引号中的变量、命令替换等会在 `source` 配置时展开；秘密通常应使用单引号，避免意外展开。

自定义值不会出现在 `container` CLI 的命令行参数中，也不会导出到宿主机 `ai-box` 进程环境，因此自定义 `PATH`、`HOME` 等名称不会改变宿主启动器的环境。启动器会把值短暂写入宿主机上权限为 `0600` 的临时 env-file：默认模式只读挂载该文件，入口脚本降权到 `node` 后再导出；dev 模式则通过 `machine run --env-file` 只注入普通用户登录进程。dev 的 root 系统配置步骤使用另一份只含有效 `AIBOX_PROXY` 和 `AIBOX_TZ` 的文件，用于刷新代理服务及系统时区，不会接触自定义 `PATH`、`LD_PRELOAD` 或 `BASH_ENV`。文件会在正常退出或收到常见终止信号时清理；系统崩溃或强制 `SIGKILL` 仍可能留下临时文件。值最终会作为环境变量对用户进程可见，所以这不构成秘密隔离。`ai-box` 不再隐式透传宿主机环境中的 `ANTHROPIC_API_KEY`、`OPENAI_API_KEY` 或其他 API key；需要传入的每个变量都必须显式列入 `AIBOX_ENV_VARS`。

重要：`ai-box` 会在宿主机上通过 `source` 执行 `aibox.conf`，该文件具有执行当前用户任意命令的能力。只使用自己创建且已检查过的配置文件，不要直接采用不可信来源的配置。

## 可选的 third_party 组件

`third_party/` 用于在构建网络受限时提供本地包。构建只识别下面三个精确文件名，三者彼此独立；缺少的组件不会安装，其他文件会被忽略。目录内容默认不提交 Git，一个空目录也可以构建包含 Claude Code 和 Codex 的核心镜像。

| 文件名 | 安装结果 | 已验证版本 | 官方来源 | 许可证 |
|---|---|---|---|---|
| `gost` | `/usr/local/bin/gost`，为上游代理提供本地 HTTP 入口 | gost 3.2.6，Linux ARM64 | [go-gost releases](https://github.com/go-gost/gost/releases) | MIT |
| `jdk8.tar.gz` | `/opt/java/jdk8`，设置 `JAVA_HOME` 和 `PATH` | Eclipse Temurin 8u492-b09，Linux AArch64 JDK | [Adoptium Temurin 8](https://adoptium.net/temurin/releases/?version=8) | GPL-2.0 with Classpath Exception |
| `maven.tar.gz` | `/opt/maven`，设置 `MAVEN_HOME` 和 `PATH` | Apache Maven 3.9.16 binary tarball | [Apache Maven downloads](https://maven.apache.org/download.cgi) | Apache-2.0 |

当前已验证资产的 SHA-256：

```text
343c3e003996ca0437b9cc47dd1500cd0475ba09f5a5f17e50851854e06a1ca7  gost
3c2253b986909c20f79d6de7a0cb957f89c243df57615897836046e24d2e5257  jdk8.tar.gz
80ffca22aed9e8b9713a232f3394fd81d7f20322df75efdb2b047dbd3e3a23bb  maven.tar.gz
```

请从官方来源下载 Linux ARM64 版本，在放入目录前核对发布方校验值及许可证。Dockerfile 会把识别到的 gost 安装为可执行文件：

```bash
aibox build
```

新增或替换任何已识别组件后都需要重建镜像。若配置了 `AIBOX_PROXY` 但镜像中没有 gost，容器会明确拒绝启动；请放入 gost 后重建，或关闭代理。Maven 可以在没有本地 JDK 的情况下单独安装，但运行 `mvn` 时仍需另行提供 Java 运行时。

这些本地资产不属于本项目许可证。重新分发前请保留归档内的 `LICENSE`、`NOTICE` 等文件，并自行确认相应许可证义务。

## 网络

默认不设置任何代理变量，容器直接访问网络。配置 `AIBOX_PROXY` 且镜像包含 gost 时，链路为：

```text
使用本地 HTTP 代理的进程
  -> http://127.0.0.1:8080
  -> gost（独立 aibox-gost UID）
  -> AIBOX_PROXY 指定的上游
```

入口脚本会设置大小写形式的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 和 `NO_PROXY`。同时安装 IPv4/IPv6 `OUTPUT` 防火墙：普通进程只允许访问 loopback，只有独立的 `aibox-gost` UID 可以连接外网。忽略代理变量、使用原始 socket 或自行发起 DNS 的程序不能直连，只会连接失败；这不是透明代理，不支持 HTTP 代理的程序仍需显式配置本地代理。

代理模式按 fail-closed 工作：防火墙或 gost 初始化失败时，入口脚本拒绝启动用户命令。启动器只在初始化时授予 `CAP_NET_ADMIN`；规则生效后会撤销 `node` 的 sudo 权限，并以空 capability 集合和 `no_new_privs` 启动 Claude、Codex 或 shell，防止容器进程清空防火墙。`socks5h://` 由代理端解析目标域名，适用于不希望容器侧解析目标域名的场景。代理地址及账密会在启动横幅中脱敏显示。

上述防火墙只属于默认的一次性容器。dev 模式会用同一上游配置刷新 machine 内的 systemd gost 服务，登录 shell 和从中启动的后台任务使用同一个 `127.0.0.1:8080`，但不会阻断主动直连。

镜像默认从 PyPI 安装第三方工具 `ai-ipcheck`，容器内可直接运行：

```bash
ipcheck
```

它可用于查看 IP、DNS、代理和时区等网络信息。该工具来自原项目 [stormzhang/ipcheck](https://github.com/stormzhang/ipcheck)，感谢原作者开放并维护此工具；其许可证和使用说明以上游仓库为准。

Apple container 会给容器分配可从宿主机访问的地址，可通过 `container list` 查看后访问容器内服务。

## 认证

使用 API key 时，把需要的变量显式写入本地 `aibox.conf`：

```bash
AIBOX_ENV_VARS=(
  'ANTHROPIC_API_KEY=replace-with-your-key'
  'OPENAI_API_KEY=replace-with-your-key'
)
```

只配置实际需要的 key，保存后运行 `aibox cc` 或 `aibox codex`。不要依赖宿主机 shell 中导出的同名变量；启动器不会隐式传入它们。

使用各 CLI 支持的交互式登录时，从 `AIBOX_ENV_VARS` 删除或注释相应 API key，再在容器内按工具提示完成登录：

```bash
aibox cc
aibox codex
```

Claude 和 Codex 的状态分别保存在仓库下的 `creds/claude/` 与 `creds/codex/`，与宿主机原有的 `~/.claude`、`~/.codex` 分离。凭据目录和包含 API key 的 `aibox.conf` 都是敏感信息，不要提交、打印到 Issue 或放入项目文件。

这一段只描述默认的一次性项目容器。`aibox dev` 读写挂载宿主 Home，因而使用该 Home 下的 CLI 配置和登录状态；启动器会按 `aibox.conf` 刷新 machine 的系统时区和本地代理服务，并把时区、语言及 `AIBOX_ENV_VARS` 注入每次 dev 登录会话。

## 安全与信任边界

容器不是“只能访问当前项目”的绝对安全边界。每次运行会显式提供以下宿主机资源：

| 宿主机资源 | 容器路径 | 用途 |
|---|---|---|
| 选定的项目目录 | `/workspace/<项目名>` | 项目读写 |
| `<仓库>/creds/claude` | `/home/node/.claude` | Claude 登录、配置及项目状态 |
| `<仓库>/creds/codex` | `/home/node/.codex` | Codex 登录及配置 |
| `~/.m2/repository` | `/home/node/.m2/repository` | Maven 依赖缓存 |
| `<仓库>/cache/gradle` | `/home/node/.gradle` | Linux 专用 Gradle 缓存和配置 |
| `<仓库>/entrypoint.sh` 的启动时快照 | `/usr/local/bin/entrypoint.sh` | 只读的运行期入口脚本 |

除入口脚本外，这些目录用于持久化读写。容器中的 AI 工具及其子进程能够读取或修改它们，项目文件的修改会立即反映到宿主机。不要为不可信代码挂载含敏感内容的项目，也不要把秘密放进 Maven/Gradle 缓存。

此外还应了解：

- `AIBOX_ENV_VARS` 中的值不会放入 `container` CLI 参数或导出到宿主启动器环境；它们会短暂存放在权限为 `0600`、只读挂载并由 `ai-box` 清理的宿主机临时 env-file 中，只在入口降权后导出给用户命令。
- 用户命令以 `node` 运行。直连模式保留容器内免密 `sudo`；代理模式会撤销 sudo、清空 capability 并启用 `no_new_privs`，避免防火墙被绕过。
- `--rm` 只删除临时容器文件系统，不删除项目、凭据和缓存。
- 项目名取自目录 basename；不同路径下的同名项目会得到相同容器工作路径，并可能共享 Claude 的项目状态。需要严格隔离时请使用不同目录名和独立凭据目录。
- 容器降低误触宿主机其他路径的风险，但不能替代代码审查、最小权限、秘密管理或容器运行时安全更新。

`aibox dev` 的边界不同：Apple container 会在首次启动时创建与宿主 UID/GID 匹配的用户，授予免密 `sudo`，并把宿主 Home 整体读写挂载进开发机。开发机的 Linux 根文件系统会跨停止和重启保留，但 Home 中的项目、凭据、SSH 配置及其他文件仍是宿主真实数据，机内进程可以读写它们。开发机会读取同一份 `aibox.conf`；若配置代理，启动器会刷新由 systemd 管理的 machine 内 gost 服务，并让登录会话使用稳定的本地 HTTP 端点；自定义变量通过权限为 `0600` 的临时 env-file 注入。但由于 machine 用户拥有 sudo 和完整系统控制权，这只是默认代理路由，不是一次性容器的 fail-closed 强制出口边界，进程可以主动绕过。`dev` 适合可信的日常开发工作流，不适合运行需要限制宿主文件访问或强制代理的不可信代码。

## 命令

```bash
# 新建临时容器
aibox [/path/to/project]             # 进入 shell，默认挂载当前目录
aibox cc [/path/to/project]          # 启动 Claude Code
aibox codex [/path/to/project]       # 启动 Codex CLI

# 持久开发机（固定名称 aibox-dev，不绑定单个项目）
aibox dev                             # 创建/启动并进入；exit 只退出当前 shell
aibox dev build [--no-cache]          # 单独构建开发机镜像
aibox dev start                       # 创建/启动并刷新代理，不进入 shell
aibox dev restart                     # 重启并刷新代理服务
aibox dev exec <command> [args...]    # 在开发机内以普通用户执行命令
aibox dev update [cc|codex]           # 升级开发机系统盘内的 AI CLI
aibox dev version [cc|codex]          # 查看开发机内实际 CLI 版本
aibox dev set memory=8G cpus=4        # 调整资源，restart 后生效
aibox dev status                      # 查看状态和配置
aibox dev stop                        # 停止，保留系统盘
aibox dev logs [-f]                   # 查看日志
aibox dev delete                      # 确认后删除开发机及系统盘；别名 rm

# 管理容器
aibox list                            # 列出运行中的 aibox 容器；别名 ls
aibox list -a                         # 包含已停止容器
aibox enter [编号|项目名|容器名]      # 进入已有容器；无参数时交互选择
aibox stop <编号|项目名|容器名>       # 停止一个容器
aibox stop --all                      # 确认后停止全部 aibox 容器
aibox logs <编号|项目名|容器名> [-f]  # 查看日志
aibox clear                           # 清理已停止容器；别名 prune

# 服务、镜像和版本
aibox start                           # 启动 Apple container 服务
aibox build [--no-cache]              # 单独构建一次性容器镜像
aibox update [cc|codex]               # 检查版本，确认后增量更新镜像
aibox version                         # 显示 Dockerfile 中锁定的 CLI 版本
aibox status                          # 显示服务、镜像、开发机、剪贴板桥接和运行中容器
aibox help                            # 命令帮助

# 剪贴板贴图（宿主机侧常驻监听，两种模式都生效）
aibox clip install                    # 启用
aibox clip status                     # 自检
aibox clip restart                    # 重启监听
aibox clip uninstall                  # 卸载
```

`enter`、`stop` 和 `logs` 使用同一套目标解析规则。编号来自当前的 `aibox list`，容器增减后应重新查看列表。`version` 和 `status` 中的 CLI 版本来自当前仓库的 `Dockerfile`，不保证与此前构建或正在运行的镜像完全一致。

新容器使用 `aibox-<项目>-<时间>-<进程号>` 名称，并带 `com.simpletang.ai-sandbox.managed=true` label。管理命令只识别 `aibox-*`，不会再把其他 `ai-*` 容器纳入批量停止或清理。升级前遗留的 `ai-*` 容器请直接用 `container list`、`container stop` 和 `container delete` 处理。

持久开发机由独立的 `container machine` 命名空间管理，固定名称为 `aibox-dev`。`aibox list/stop/clear` 只操作普通一次性容器，不会停止或删除开发机。`aibox dev` 会在开发机已停止时自动启动它；`aibox dev start` 只启动并刷新 machine 的系统时区与代理服务，`restart` 会重启后做同样的刷新，只有 `aibox dev delete` 会删除持久系统盘。语言和自定义变量是会话环境，在裸 `aibox dev` 或 `dev exec` 启动的进程中生效；时区除设置会话 `TZ` 外，也会更新 machine 的 `/etc/localtime` 和 `/etc/timezone`。`dev exec` 分配交互式 TTY。

## 剪贴板贴图

终端只能把**文本**当作键盘输入送进 tty，图片传不过来；要粘贴图片，必须由运行中的程序自己去读操作系统剪贴板，而沙箱里既没有 X11/Wayland，也够不到 macOS 的剪贴板。因此默认情况下容器内的 Claude Code 无法用 Ctrl+V 贴图。

`aibox clip install` 会在 macOS 上启用一个 launchd 常驻监听：剪贴板里一出现图片，就写成 PNG 落到 `~/.clipboard-bridge/`；镜像里预置的 `xclip` 垫片读取该目录，于是 Ctrl+V 按原生方式工作。不需要 X server，也不开任何网络端口。

```bash
aibox clip install     # 在 macOS 上执行一次
# 复制一张图后
aibox clip status      # 应显示「有图可粘」
```

`aibox status` 与 `aibox dev status` 均包含一行 `剪贴板贴图`，会区分「未启用 / 已启用且当前有图 / 已启用但当前无图 / 心跳超时（监听已停）」四种情况，一屏自检时即可发现桥接失效。

监听用 JXA 读 `NSPasteboard.changeCount` 检测剪贴板变化（O(1) 整数，不触发图像渲染），空闲时几乎不耗 CPU。垫片默认一张图只交付一次，避免连按 Ctrl+V 叠出多张相同附件（`CLIP_BRIDGE_ONESHOT=0` 可关闭）。

沙箱里请按 **Ctrl+V**，不是 ⌘V —— ⌘V 会被 macOS 终端截走当作文本粘贴，根本不会传进容器。

两种运行模式的桥接路径不同，由 `ai-box` 自动注入 `CLIP_BRIDGE_DIR`：`aibox dev` 已用 `--home-mount rw` 挂载整个宿主 Home，路径与 macOS 侧一致；一次性 `aibox` 只挂项目目录，因此额外把 `~/.clipboard-bridge` 只读挂到 `/run/aibox/clipboard-bridge`。没装宿主机侧时不挂载，垫片会安静地报告「没有图」，不影响任何其他功能。

监听**只镜像图片，不镜像剪贴板文本**，避免密码等敏感文本落盘。原理、架构图与排错见 [`clipboard-bridge/README.md`](clipboard-bridge/README.md)。

## Java 与构建缓存

Java 支持完全可选：

- 放入 `jdk8.tar.gz` 后提供 `java`、`javac` 和 `JAVA_HOME`。
- 放入 `maven.tar.gz` 后提供 `mvn` 和 `MAVEN_HOME`；Maven 自身仍需要 JDK。
- Gradle 不内置发行版，项目可使用 `./gradlew`；它同样需要可用的 JDK。

Maven 仓库从宿主机 `~/.m2/repository` 挂载，宿主机与容器同时写入时可能发生并发冲突。Gradle 使用仓库下独立的 `cache/gradle/`，避免 macOS 与 Linux 共用平台相关缓存。即使未安装 JDK 或 Maven，这两个缓存挂载仍会创建，不影响核心 CLI。

启用代理时，入口脚本会为 Gradle 添加带标记的代理配置块；Maven 的 `settings.xml` 不存在或原本由 ai-box 管理时，才会写入代理配置，不覆盖用户自有的文件。切回直连后，入口脚本只移除自己管理的内容并保留其他配置。普通 Java 程序通常不读取 `HTTP_PROXY`；代理模式下直连会被防火墙拒绝，需要显式传入 JVM 参数：

```bash
java -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=8080 \
     -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=8080 \
     -jar app.jar
```

## 更新

```bash
aibox update           # Claude Code 和 Codex
aibox update cc        # 仅 Claude Code
aibox update codex     # 仅 Codex
```

更新命令从 npm 镜像查询版本，显示差异并等待确认；确认后会修改 `Dockerfile` 中的锁定版本，然后用 `Dockerfile.update` 做**增量更新**：在现有镜像之上只叠一层 `npm install`，只下载本次有更新的包，不重跑 apt/locale/pip 等旧层，也不依赖 builder 的层缓存（builder 删除重建后缓存会全丢，全量构建就得重下所有依赖）。若本地没有镜像或增量构建失败，会提示回退全量构建。新的一次性容器使用新镜像，已经运行的容器不受影响。

持久开发机有自己的可写系统盘，创建后不会随基础镜像更新。`aibox dev update [cc|codex]` 会直接升级该系统盘中的 AI CLI，使用 dev 本地 gost 代理（如已配置），不改写 `Dockerfile` 版本钉。若要按最新仓库镜像配方重建，先备份系统盘内需要保留的内容；基础镜像有变化时先执行 `aibox build`，再执行 `aibox dev build`。随后用 `aibox dev delete` 删除旧开发机并运行 `aibox dev` 重新创建。宿主 Home 中的文件不会随开发机删除。

增量更新每次都会给镜像叠加一层新 layer（旧版本文件仍留在下层），多次更新后镜像会缓慢变大，可用 `aibox build` 全量重建压平——`update` 已同步改写 `Dockerfile` 的版本 ARG，全量重建得到的版本与增量结果一致。修改 `Dockerfile`、`network-lockdown.sh`、`LOCALE_GEN` 或已识别的 `third_party` 文件后运行 `aibox build`；修改 `Dockerfile.dev`、`dev-*.sh` 或开发机 service 后运行 `aibox dev build`。如果开发机镜像需要继承刚重建的基础镜像，按顺序执行这两条命令。已创建开发机的系统盘不会自动获得新的 dev helper，需要删除后重建。修改 `aibox.conf` 或宿主端 `ai-box` 后下次启动即可生效；普通 `entrypoint.sh` 修改也会通过快照生效，但涉及镜像工具、用户或权限模型时仍须全量重建。

本次引入强制代理防火墙后必须至少执行一次 `aibox build`：旧镜像没有 iptables、专用 gost 用户和 root 初始化入口，不能只靠运行时 entrypoint 快照升级。

## 排障

| 现象 | 处理 |
|---|---|
| 找不到 `container` | 安装或升级 Apple container，并确认其命令在 `PATH` 中 |
| 服务未启动 | 运行 `aibox start`，再用 `aibox status` 检查 |
| `aibox dev` 提示缺少开发机镜像 | 运行 `aibox dev build`；若提示缺少基础镜像，先运行 `aibox build` |
| 重启 Mac 后首次运行 `aibox dev` 提示 `Failed to connect to bus` | 更新宿主端 `ai-box`；启动器会等待 machine 的 systemd manager 就绪后再刷新系统配置，现有开发机无需删除 |
| builder 报 `-9816: server closed session` | 运行 `container builder delete --force`，然后重新构建 |
| 配置代理后提示缺少 gost | 放入 `third_party/gost` 并重建，或将 `AIBOX_PROXY` 设为空 |
| 提示缺少强制代理组件或防火墙初始化失败 | 运行 `aibox build` 全量重建；仍失败时检查 Apple container 是否接受启动器传入的 `CAP_NET_ADMIN` |
| `socks5://` 下域名解析失败 | 尝试 `socks5h://`，让上游解析域名 |
| locale 回退到 `C.UTF-8` | 将 locale 加入 `LOCALE_GEN` 后重建 |
| `mvn` 提示找不到 Java | 同时提供 `jdk8.tar.gz`，或自行安装兼容 JDK |
| 长会话卡顿或被 OOM 终止 | 结束并恢复会话，或按主机容量调整 `MEMORY` |
| 同名项目的 Claude 状态混合 | 使用不同的目录 basename，或为实例拆分凭据目录 |
| 构建无法下载 APT/PyPI/npm 依赖 | 检查 builder 网络和 DNS；本地三方包不会替代这些在线依赖 |
| 挂载的项目目录在容器内为空 | Apple container 的单文件挂载会连带共享其父目录；父目录若同时是另一挂载的源（如挂载沙箱仓库自身时的 `entrypoint.sh`），该目录会静默挂空。`ai-box` 已改挂 entrypoint 启动时快照规避；仍出现则更新宿主端 `ai-box` 或重启 container 服务 |

日志中可能出现项目路径、代理主机或工具输出。提交问题前请删除 API key、代理账密、token 及业务数据。

## 开发、贡献与问题报告

提交改动前至少运行：

```bash
bash -n ai-box entrypoint.sh ai-box-completion.sh
shellcheck ai-box entrypoint.sh ai-box-completion.sh  # 已安装 ShellCheck 时
aibox build                                          # 有 Apple container 环境时
aibox dev build                                      # 涉及开发机镜像时
```

可选组件相关改动应额外验证空 `third_party/`、单独每个组件及所需组合。涉及用户行为时，请同步更新中文和英文 README。普通缺陷和功能请求请通过 GitHub Issues 提交，并附上脱敏后的 macOS、Apple container、`aibox status` 和复现信息。

安全漏洞请优先使用仓库的 GitHub Security Advisory 私密报告入口。若该入口尚未启用，只提交不含利用细节和秘密的最小公开 Issue，请维护者建立私密沟通渠道；不要公开有效凭据、代理账号或未修复漏洞细节。

## 卸载

先结束容器，再删除镜像、软链和仓库：

```bash
aibox stop --all
aibox clear
aibox dev delete
container image delete ai-sandbox:latest
container image delete ai-sandbox-dev:latest
rm "$HOME/.local/bin/aibox"
```

最后删除克隆目录。删除前按需备份 `creds/`；删除仓库也会删除容器专用登录状态和 Gradle 缓存。宿主机的 `~/.m2/repository` 不会随仓库删除。若 shell 配置中加入了补全或 `PATH` 行，也请一并移除。

## 许可证与第三方软件

本项目代码按 [MIT License](LICENSE) 发布。可选的 gost、Temurin 和 Maven，以及基础镜像、系统包、Claude Code、Codex CLI 和 `ai-ipcheck`，均由各自作者按各自许可证或服务条款提供，不因本仓库的 MIT License 而改变。下载、使用或重新分发前，请查阅上游许可、NOTICE 和条款。
