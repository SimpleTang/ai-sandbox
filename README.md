# ai-sandbox

[中文](README.md) | [English](README.en.md)

在 Apple silicon Mac 上通过 [Apple container](https://github.com/apple/container) 运行 Claude Code 和 Codex CLI。默认的 `aibox` 进入一台基于 `container machine` 的长期容器：宿主 Home 按原路径读写挂载，机内装的软件和系统配置保存在长期保留的系统盘上；`aibox tmp` 则每次创建一个只挂载当前项目及明确持久化目录、用完即删的临时容器。

本项目是社区项目，与 Apple、Anthropic 或 OpenAI 无隶属或背书关系。Claude、Claude Code、OpenAI 和 Codex 等名称及商标归其各自权利人所有。使用相关服务时，请遵守对应条款和当地法律。

## 功能

- 一条 `aibox` 命令进入 shell，或直接启动 `claude` / `codex`。
- 默认的长期容器固定名为 `aibox-dev`，不绑定单个项目，可在其中处理 Home 下的多个项目、安装长期保留的软件；服务未启动时自动启动。
- `aibox tmp` 为每个终端会话创建独立的 `--rm` 临时容器，只挂载指定项目，支持多个项目并行运行。
- Claude/Codex 登录状态保存在宿主机 `~/.aibox/`，两种容器共用，与 Mac 本机 CLI 的 `~/.claude`、`~/.codex` 分离；项目文件及构建缓存按明确规则持久化。
- 默认直连；配置 gost 上游代理时，临时容器启用 IPv4/IPv6 出口防火墙，禁止其他进程绕过代理直连。
- 时区和 locale 可跟随宿主机，也可逐次或通过配置文件指定。
- 镜像默认安装 `ai-ipcheck`，可直接使用 `ipcheck` 诊断容器网络环境。
- 提供临时容器的列表、进入、停止、日志，以及状态自检、CLI 更新和 Tab 补全。
- `aibox clip install` 启用剪贴板图片桥接，沙箱内的 Claude Code 可用 Ctrl+V 直接粘贴宿主机剪贴板里的图片。
- `third_party/` 中的 gost、JDK 8 和 Maven 均为独立可选组件。

## 兼容性

| 项目 | 要求或当前配置 |
|---|---|
| 主机 | Apple silicon Mac |
| 操作系统 | macOS 26；Apple 官方不支持更旧版本 |
| 容器运行时 | [Apple container](https://github.com/apple/container)（已验证 1.6.0，最低要求 1.0.0；不是 Docker） |
| 宿主脚本 | 兼容 macOS 自带 Bash 3.2；日常可从 zsh 调用 |
| 容器架构 | Linux ARM64，基础镜像为 `node:22-bookworm` |
| VM 内存 | 临时容器和长期容器默认均为 `8192M`；临时容器可在 `ai-box` 的 `MEMORY` 中调整，长期容器的 `DEV_MEMORY` 只在首次创建时使用，之后用 `aibox set memory=...` 调整 |

构建仍会联网下载基础镜像、APT/PyPI 包以及 Claude Code/Codex npm 包。`third_party/` 可为空并不表示镜像支持完全离线构建。

## 安装

### 推荐：安装向导

```bash
git clone https://github.com/SimpleTang/ai-sandbox.git
cd ai-sandbox
./setup.sh
```

向导会逐步检查并完成下面几件事。每一步先检测现状，已完成的自动跳过，所以可以随时中断、反复运行：

1. 检查 Mac 环境：Apple silicon 与 macOS 26。
2. 安装 Apple container：可自动下载已验证版本（当前为 1.6.0）的官方安装包，核对 Apple 签名后打开系统安装器；也可以只打开下载页。已安装时检查版本：低于最低要求会提示升级，高于已验证版本只提示「未经验证」。
3. 启动 container 服务；首次启动会下载 Apple 推荐的默认 Linux 内核。
4. 安装 `aibox` 命令：在 `~/.local/bin` 创建软链，按需把该目录加入 `PATH` 并启用 Tab 补全（写入 `~/.zshrc`，bash 用户为 `~/.bash_profile`）。
5. 生成 `aibox.conf`：代理、时区、语言和认证方式（容器内账号登录或 API key）。选择代理时会校验地址格式，把 `127.0.0.1` 这类容器内不可达的地址换成宿主机在容器网络中的地址，可自动下载 gost 并按下文记录的 SHA-256 校验，还可以测试代理能否访问 Claude API。已有配置时默认保留；修改会先备份原文件，并保留 `AIBOX_ENV_VARS` 中与认证无关的条目。
6. 迁移旧版数据：发现旧版留下的登录状态和配置时，选择用长期容器的、临时容器的或合并（详见「认证」一节）。
7. 构建镜像：两个镜像 `ai-sandbox:latest`（基础镜像，临时容器使用）和 `ai-sandbox-dev:latest`（长期容器镜像）都需要，缺任一个就运行 `aibox build` 依次构建。
8. 可选启用剪贴板贴图。

完成后向导会提示下一步：`aibox cc` 在长期容器里启动 Claude Code，`aibox tmp cc` 改用临时容器。安装完成后可随时运行 `aibox setup` 重跑向导调整配置；`aibox setup --check` 只检查各步骤状态、不做任何修改，适合排查「哪一步没配好」。

想自己掌控每一步，或者向导在你的环境里失败时，按下面的手动步骤操作。

### 手动安装

#### 1. 安装 Apple container

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

1. 打开 [Releases 页面](https://github.com/apple/container/releases)，下载 Apple 签名安装包（`container-<版本>-installer-signed.pkg`）。本项目当前验证的是 1.6.0；更新的版本一般也能用，`aibox status` 会标出「未经验证」。
2. 双击 `.pkg`，按安装器提示操作；系统会要求管理员密码，以便把文件安装到 `/usr/local`。
3. 启动 container 系统服务并验证 CLI：

```bash
container system start
container --version
container list
```

`container list` 即使没有运行中的容器也应能正常返回。之后进入长期容器的命令（`aibox`、`aibox cc`、`aibox start` 等）在服务未启动时会自动执行 `container system start`；临时容器和 `aibox build` 不会自动启动服务。

已经安装旧版本时，Apple 提供的升级方式是先停止服务，再运行安装在 `/usr/local/bin` 下的更新脚本。建议用 `-v` 指定本项目已验证的版本；不带参数则升级到最新版。升级会停止所有临时容器和长期容器，并需要管理员密码：

```bash
container system stop
/usr/local/bin/update-container.sh -v 1.6.0
container system start
```

同一脚本加 `-f` 也可以装回旧版本（例如 `-v 1.0.0 -f`）。`aibox status` 第一行会显示已安装版本与已验证版本。

具体安装、升级或卸载行为可能随 Apple container 版本变化，请以[官方仓库说明](https://github.com/apple/container#initial-install)为准。

#### 2. 安装 ai-sandbox

克隆本仓库。仓库可以放在任意路径；`ai-box` 会根据脚本自身位置定位构建文件。建议放在宿主 Home 内：长期容器只能看到 Home，仓库在 Home 内时启动器才能在每次启动时把仓库里的辅助脚本同步进已有的长期容器（见「更新」）。

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

最省事的方式是运行 `aibox setup`（或在仓库里运行 `./setup.sh`），按向导完成安装、配置和镜像构建。手动操作时，确认 container 服务已启动后构建镜像，再进入项目目录：

```bash
aibox build      # 依次构建基础镜像和长期容器镜像；向导已构建时可跳过

cd ~/your-project
aibox cc         # 在长期容器里启动 Claude Code（首次运行会创建长期容器）
aibox codex      # 在长期容器里启动 Codex CLI
aibox            # 只进入长期容器的 shell

aibox tmp cc     # 改用用完即删的临时容器，只挂载当前项目
```

两种容器的取舍：

- **长期容器**（`aibox`）：适合可信的日常开发。整个宿主 Home 读写挂载，机内安装的软件和系统配置跨停止、重启保留。工作目录必须在宿主 Home 内：显式给出 Home 外的路径会报错并建议改用 `aibox tmp`；当前目录不在 Home 内时自动改为进入 Home 并给出提示。带 `cc` 或 `codex` 时工具退出后留在机内 shell；`exit` 只退出 shell，不会停止长期容器（用 `aibox stop` 停止）。
- **临时容器**（`aibox tmp`）：适合不完全信任的代码。只挂载指定项目和少数明确的持久化目录，配置代理时有 fail-closed 出口防火墙。带 `cc` 或 `codex` 时工具退出后留在容器 shell；再次执行 `exit` 才会结束并删除该容器。项目文件及持久化目录中的变更不会随容器删除。

需要 API key、其他自定义环境变量、代理、固定时区或固定语言时，运行 `aibox setup` 按提示生成配置；也可以手动创建：

```bash
cd /path/to/ai-sandbox
cp aibox.conf.example aibox.conf
chmod 600 aibox.conf
# 编辑 aibox.conf，然后重新运行 aibox；无需重建镜像
```

`aibox.conf` 可能包含 API key、代理凭据等秘密，已由 `.gitignore` 和 `.dockerignore` 排除，不要提交它，也不要把文件内容粘贴到 Issue 或日志中。

## 运行期配置

`aibox.conf` 是 Bash 配置片段，两种容器共用：

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

自定义值不会出现在 `container` CLI 的命令行参数中，也不会导出到宿主机 `ai-box` 进程环境，因此自定义 `PATH`、`HOME` 等名称不会改变宿主启动器的环境。启动器会把值短暂写入宿主机上权限为 `0600` 的临时 env-file：临时容器只读挂载该文件，入口脚本降权到 `node` 后再导出；长期容器则通过 `machine run --env-file` 只注入普通用户登录进程。长期容器的 root 系统配置步骤使用另一份文件，其中只有有效的 `AIBOX_PROXY`、`AIBOX_TZ`、登录状态目录和仓库路径，用于同步辅助脚本、刷新代理服务及系统时区，不会接触自定义 `PATH`、`LD_PRELOAD` 或 `BASH_ENV`。文件会在正常退出或收到常见终止信号时清理；系统崩溃或强制 `SIGKILL` 仍可能留下临时文件。值最终会作为环境变量对用户进程可见，所以这不构成秘密隔离。`ai-box` 不再隐式透传宿主机环境中的 `ANTHROPIC_API_KEY`、`OPENAI_API_KEY` 或其他 API key；需要传入的每个变量都必须显式列入 `AIBOX_ENV_VARS`。

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

新增或替换任何已识别组件后都需要重建镜像。例外是 gost：仓库在宿主 Home 内时，已有的长期容器每次启动会把 `third_party/gost` 同步进系统盘，无需重建；临时容器仍要重建镜像才能用上。若配置了 `AIBOX_PROXY` 但容器里没有 gost，容器会明确拒绝启动；请放入 gost 后重建，或关闭代理。Maven 可以在没有本地 JDK 的情况下单独安装，但运行 `mvn` 时仍需另行提供 Java 运行时。

这些本地资产不属于本项目许可证。重新分发前请保留归档内的 `LICENSE`、`NOTICE` 等文件，并自行确认相应许可证义务。

## 网络

默认不设置任何代理变量，容器直接访问网络。临时容器配置 `AIBOX_PROXY` 且镜像包含 gost 时，链路为：

```text
使用本地 HTTP 代理的进程
  -> http://127.0.0.1:8080
  -> gost（独立 aibox-gost UID）
  -> AIBOX_PROXY 指定的上游
```

入口脚本会设置大小写形式的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 和 `NO_PROXY`。同时安装 IPv4/IPv6 `OUTPUT` 防火墙：普通进程只允许访问 loopback，只有独立的 `aibox-gost` UID 可以连接外网。忽略代理变量、使用原始 socket 或自行发起 DNS 的程序不能直连，只会连接失败；这不是透明代理，不支持 HTTP 代理的程序仍需显式配置本地代理。

代理模式按 fail-closed 工作：防火墙或 gost 初始化失败时，入口脚本拒绝启动用户命令。启动器只在初始化时授予 `CAP_NET_ADMIN`；规则生效后会撤销 `node` 的 sudo 权限，并以空 capability 集合和 `no_new_privs` 启动 Claude、Codex 或 shell，防止容器进程清空防火墙。`socks5h://` 由代理端解析目标域名，适用于不希望容器侧解析目标域名的场景。代理地址及账密会在启动横幅中脱敏显示。

上述防火墙只属于临时容器。长期容器会用同一上游配置刷新机内由 systemd 管理的 gost 服务，登录 shell 和从中启动的后台任务使用同一个 `127.0.0.1:8080`，但不会阻断主动直连。

镜像默认从 PyPI 安装第三方工具 `ai-ipcheck`，容器内可直接运行：

```bash
ipcheck
```

它可用于查看 IP、DNS、代理和时区等网络信息。该工具来自原项目 [stormzhang/ipcheck](https://github.com/stormzhang/ipcheck)，感谢原作者开放并维护此工具；其许可证和使用说明以上游仓库为准。

Apple container 会给容器分配可从宿主机访问的地址，可通过 `container list` 查看临时容器的地址后访问容器内服务；长期容器的地址见 `aibox status`。

## 认证

使用 API key 时，把需要的变量显式写入本地 `aibox.conf`：

```bash
AIBOX_ENV_VARS=(
  'ANTHROPIC_API_KEY=replace-with-your-key'
  'OPENAI_API_KEY=replace-with-your-key'
)
```

只配置实际需要的 key，保存后运行 `aibox cc` 或 `aibox codex`（临时容器为 `aibox tmp cc` / `aibox tmp codex`）。不要依赖宿主机 shell 中导出的同名变量；启动器不会隐式传入它们。

使用各 CLI 支持的交互式登录时，从 `AIBOX_ENV_VARS` 删除或注释相应 API key，再在容器内按工具提示完成登录：

```bash
aibox cc
aibox codex
```

Claude 和 Codex 的登录状态分别保存在宿主机的 `~/.aibox/claude/` 与 `~/.aibox/codex/`（`~/.aibox` 权限为 `700`），两种容器共用，在任一种容器里登录一次即可；它们与 Mac 本机 CLI 使用的 `~/.claude`、`~/.codex` 分离。临时容器把这两个目录挂载到 `/home/node/.claude` 与 `/home/node/.codex`。长期容器里普通用户的 `$HOME` 是机内系统盘上的 `/home/<用户>`，而宿主 Home 挂在原路径；启动器每次启动时把宿主侧路径写入机内 `/etc/aibox/state-dir`，登录 profile 据此把 `CLAUDE_CONFIG_DIR` 和 `CODEX_HOME` 指向宿主的 `~/.aibox/claude` 与 `~/.aibox/codex`。登录状态目录和包含 API key 的 `aibox.conf` 都是敏感信息，不要提交、打印到 Issue 或放入项目文件。

Claude 按工作目录的绝对路径区分项目状态：临时容器里是 `/workspace/<项目名>`，长期容器里是项目在宿主上的原路径，因此同一项目在两种容器中的会话记录和项目记忆互不相通。

从旧版本升级时：旧版两种容器的 Claude / Codex 状态各在一处——临时容器在仓库下的 `creds/claude/`、`creds/codex/`，长期容器在机内用户自己的 `/home/<用户>/.claude`、`.codex`（系统盘上，包括 `CLAUDE.md`、`settings.json`、插件、项目 memory 和会话历史）。新版首次启动任一容器、运行 `aibox setup` 或 `aibox migrate` 时会检测这些旧数据：

- 两边都有时让你选择：用长期容器的、用临时容器的，或者合并（默认）。合并以长期容器的为主，临时容器里独有的文件补进来；两边按工作路径区分的会话历史都会保留；同名而内容不同的文件（如 `CLAUDE.md`）以 `*.from-tmp` 另存在旁边，由你手动合并。也可以选「稍后再说」，本次不启动。
- 只有一边有时直接复制，不再询问。
- 旧数据不会被删除：复制成功后，机内旧目录改名为 `.claude.pre-aibox-<时间>`，原位置换成指向 `~/.aibox` 的软链接，这样不经过 aibox 进入长期容器的入口也不会再写旧目录；仓库 `creds/` 挪到 `~/.aibox/legacy/creds-<时间>/`。`~/.aibox` 里已有的内容会先挪到 `<名字>.before-migrate-<时间>`。
- 迁移前会检查长期容器里是否还有 Claude Code / Codex 在运行、是否有旧版启动的临时容器。它们会继续写旧位置，所以默认不迁移，需要你确认。**建议迁移前退出所有正在运行的会话。**

迁移完成后写入 `~/.aibox/.migrated`，以后不再询问。确认新环境无误后，可以自行删除上述备份。

长期容器使用同一份 `aibox.conf`：启动器会按它刷新机内的系统时区和本地代理服务，并把时区、语言及 `AIBOX_ENV_VARS` 注入每次登录会话。

## 安全与信任边界

容器不是“只能访问当前项目”的绝对安全边界。临时容器每次运行会显式提供以下宿主机资源：

| 宿主机资源 | 容器路径 | 用途 |
|---|---|---|
| 选定的项目目录 | `/workspace/<项目名>` | 项目读写 |
| `~/.aibox/claude` | `/home/node/.claude` | Claude 登录、配置及项目状态（与长期容器共用） |
| `~/.aibox/codex` | `/home/node/.codex` | Codex 登录及配置（与长期容器共用） |
| `~/.m2/repository` | `/home/node/.m2/repository` | Maven 依赖缓存 |
| `<仓库>/cache/gradle` | `/home/node/.gradle` | Linux 专用 Gradle 缓存和配置 |
| `<仓库>/entrypoint.sh` 的启动时快照 | `/usr/local/bin/entrypoint.sh` | 只读的运行期入口脚本 |
| `~/.clipboard-bridge`（仅启用剪贴板桥接时） | `/run/aibox/clipboard-bridge` | 只读的剪贴板图片 |

除只读的两项外，这些目录用于持久化读写。容器中的 AI 工具及其子进程能够读取或修改它们，项目文件的修改会立即反映到宿主机。不要为不可信代码挂载含敏感内容的项目，也不要把秘密放进 Maven/Gradle 缓存。

此外还应了解：

- `AIBOX_ENV_VARS` 中的值不会放入 `container` CLI 参数或导出到宿主启动器环境；它们会短暂存放在权限为 `0600`、只读挂载并由 `ai-box` 清理的宿主机临时 env-file 中，只在入口降权后导出给用户命令。
- 用户命令以 `node` 运行。直连模式保留容器内免密 `sudo`；代理模式会撤销 sudo、清空 capability 并启用 `no_new_privs`，避免防火墙被绕过。
- `--rm` 只删除临时容器文件系统，不删除项目、登录状态和缓存。
- 项目名取自目录 basename；不同路径下的同名项目会得到相同容器工作路径，并可能共享 Claude 的项目状态。需要严格隔离时请使用不同目录名。
- 容器降低误触宿主机其他路径的风险，但不能替代代码审查、最小权限、秘密管理或容器运行时安全更新。

长期容器的边界不同：Apple container 会在首次启动时创建与宿主 UID/GID 匹配的用户，授予免密 `sudo`，并把宿主 Home 按原路径整体读写挂载进去。机内 Linux 根文件系统会跨停止和重启保留，但 Home 中的项目、`~/.aibox` 登录状态、Mac 本机 CLI 的 `~/.claude` / `~/.codex`、SSH 配置及其他文件仍是宿主真实数据，机内进程可以读写它们。长期容器会读取同一份 `aibox.conf`；若配置代理，启动器会刷新由 systemd 管理的机内 gost 服务，并让登录会话使用稳定的本地 HTTP 端点；自定义变量通过权限为 `0600` 的临时 env-file 注入。但由于机内用户拥有 sudo 和完整系统控制权，这只是默认代理路由，不是临时容器的 fail-closed 强制出口边界，进程可以主动绕过。长期容器适合可信的日常开发工作流，不适合运行需要限制宿主文件访问或强制代理的不可信代码——这类代码请用 `aibox tmp`。

## 命令

```bash
# 安装与配置
aibox setup                           # 安装向导：逐步检查并完成安装和配置，可反复运行
aibox setup --check                   # 只检查各步骤状态，不做任何修改

# 长期容器（默认；固定名称 aibox-dev，不绑定单个项目）
aibox [/path]                         # 创建/启动并进入 shell，工作目录默认为当前目录；exit 只退出 shell
aibox cc [/path]                      # 进入并启动 Claude Code；cc 也可写作 claude
aibox codex [/path]                   # 进入并启动 Codex CLI
aibox start                           # 创建/启动并刷新代理，不进入 shell
aibox restart                         # 重启并刷新代理服务
aibox exec <command> [args...]        # 以普通用户在长期容器内执行命令
aibox update [cc|codex]               # 检查机内 CLI 新版，确认后更新
aibox version [cc|codex]              # 查看机内实际安装的 CLI 版本
aibox set memory=8G cpus=4            # 调整资源，restart 后生效
aibox stop                            # 停止，保留系统盘
aibox logs [-f]                       # 查看日志
aibox delete                          # 确认后删除长期容器及系统盘；别名 rm
aibox migrate                         # 把旧版的登录状态和配置迁移到 ~/.aibox（首次启动时也会自动检查）
aibox build [--no-cache]              # 依次构建基础镜像和长期容器镜像

# 临时容器（用完即删，只挂载指定项目）
aibox tmp [/path/to/project]          # 进入 shell，默认挂载当前目录
aibox tmp cc [/path/to/project]       # 启动 Claude Code；cc 也可写作 claude
aibox tmp codex [/path/to/project]    # 启动 Codex CLI
aibox tmp list [-a]                   # 列出运行中的临时容器；-a 包含已停止；别名 ls
aibox tmp enter [编号|项目名|容器名]  # 进入已有容器；无参数时交互选择
aibox tmp stop <编号|项目名|容器名>   # 停止一个容器
aibox tmp stop --all                  # 确认后停止全部临时容器
aibox tmp logs <编号|项目名|容器名> [-f]  # 查看启动日志
aibox tmp clear                       # 确认后清理已停止容器；别名 prune
aibox tmp build [--no-cache]          # 只构建基础镜像
aibox tmp update [cc|codex]           # 检查版本，确认后增量更新基础镜像
aibox tmp version                     # 显示 Dockerfile 中锁定的 CLI 版本

# 通用
aibox status                          # 服务、镜像、版本锁定、登录状态目录、剪贴板桥接、长期容器详情和运行中的临时容器
aibox help                            # 命令帮助（也认 -h / --help）

# 剪贴板贴图（宿主机侧常驻监听，两种容器都生效）
aibox clip install                    # 启用
aibox clip status                     # 自检
aibox clip restart                    # 重启监听
aibox clip doctor                     # 贴不上图时诊断
aibox clip uninstall                  # 卸载
```

`aibox tmp enter`、`stop` 和 `logs` 使用同一套目标解析规则：编号、项目名或完整容器名。编号来自当前的 `aibox tmp list`，容器增减后应重新查看列表。`aibox tmp enter` 只是在已有容器里再开一个 shell，退出它不会停止原容器。`aibox tmp version` 和 `aibox status` 中的版本行来自当前仓库的 `Dockerfile`，不保证与此前构建或正在运行的镜像完全一致；长期容器里实际安装的版本用 `aibox version` 查看。

`aibox status` 在一屏内显示服务、基础镜像、长期容器镜像、`Dockerfile` 锁定的 CLI 版本、登录状态目录 `~/.aibox`、剪贴板桥接，然后是长期容器详情（运行状态、镜像、CPU、内存、系统盘、IP、Home 挂载方式、机内用户等）和运行中的临时容器。服务正常但无法查询长期容器时返回非零。

新的临时容器使用 `aibox-<项目>-<时间>-<进程号>` 名称，并带 `com.simpletang.ai-sandbox.managed=true` label。管理命令只识别 `aibox-*`，不会再把其他 `ai-*` 容器纳入批量停止或清理。升级前遗留的 `ai-*` 容器请直接用 `container list`、`container stop` 和 `container delete` 处理。

长期容器由独立的 `container machine` 命名空间管理，固定名称为 `aibox-dev`。`aibox tmp list/stop/clear` 只操作临时容器，不会停止或删除长期容器。`aibox`、`aibox cc`、`aibox codex` 会在长期容器不存在时用 `ai-sandbox-dev:latest` 创建它，已停止时自动启动它；`aibox start` 只启动并刷新机内的系统时区与代理服务，`restart` 会重启后做同样的刷新，只有 `aibox delete` 会删除持久系统盘。语言和自定义变量是会话环境，在 `aibox`、`aibox cc` / `codex` 或 `aibox exec` 启动的进程中生效；时区除设置会话 `TZ` 外，也会更新机内的 `/etc/localtime` 和 `/etc/timezone`。`aibox exec` 分配交互式 TTY。

旧版命令的去向：`aibox dev ...` 已移除，原来的持久开发机就是现在的默认长期容器（`aibox dev` → `aibox`，`aibox dev start` → `aibox start`，依此类推）；原来顶层的一次性容器命令都移到了 `aibox tmp` 下，直接运行 `aibox list`、`ls`、`enter`、`clear` 或 `prune` 会报错并提示改用 `aibox tmp ...`；原来启动 container 服务的 `aibox start` 现在用于启动长期容器（服务未启动时一并启动）。

## 剪贴板贴图

终端只能把**文本**当作键盘输入送进 tty，图片传不过来；要粘贴图片，必须由运行中的程序自己去读操作系统剪贴板，而沙箱里既没有 X11/Wayland，也够不到 macOS 的剪贴板。因此默认情况下容器内的 Claude Code 无法用 Ctrl+V 贴图。

`aibox clip install` 会在 macOS 上启用一个 launchd 常驻监听：剪贴板里一出现图片，就写成 PNG 落到 `~/.clipboard-bridge/`；镜像里预置的 `xclip` 垫片读取该目录，于是 Ctrl+V 按原生方式工作。不需要 X server，也不开任何网络端口。

```bash
aibox clip install     # 在 macOS 上执行一次
# 复制一张图后
aibox clip status      # 应显示「有图可粘」
```

`aibox status` 包含一行 `剪贴板贴图`，会区分「未启用 / 已启用且当前有图 / 已启用但当前无图 / 心跳超时（监听已停）」等情况，一屏自检时即可发现桥接失效。

监听用 JXA 读 `NSPasteboard.changeCount` 检测剪贴板变化（O(1) 整数，不触发图像渲染），空闲时几乎不耗 CPU。垫片默认一张图只交付一次，避免连按 Ctrl+V 叠出多张相同附件（`CLIP_BRIDGE_ONESHOT=0` 可关闭）。

沙箱里请按 **Ctrl+V**，不是 ⌘V —— ⌘V 会被 macOS 终端截走当作文本粘贴，根本不会传进容器。

两种容器的桥接路径不同，由 `ai-box` 自动注入 `CLIP_BRIDGE_DIR`：长期容器已用 `--home-mount rw` 挂载整个宿主 Home，路径与 macOS 侧一致；临时容器只挂项目目录，因此额外把 `~/.clipboard-bridge` 只读挂到 `/run/aibox/clipboard-bridge`（项目目录本身已包含该目录时直接复用项目挂载）。没装宿主机侧时不挂载，垫片会安静地报告「没有图」，不影响任何其他功能。

监听**只镜像图片，不镜像剪贴板文本**，避免密码等敏感文本落盘。原理、架构图与排错见 [`clipboard-bridge/README.md`](clipboard-bridge/README.md)。

## Java 与构建缓存

Java 支持完全可选：

- 放入 `jdk8.tar.gz` 后提供 `java`、`javac` 和 `JAVA_HOME`。
- 放入 `maven.tar.gz` 后提供 `mvn` 和 `MAVEN_HOME`；Maven 自身仍需要 JDK。
- Gradle 不内置发行版，项目可使用 `./gradlew`；它同样需要可用的 JDK。

临时容器的 Maven 仓库从宿主机 `~/.m2/repository` 挂载，宿主机与容器同时写入时可能发生并发冲突。Gradle 使用仓库下独立的 `cache/gradle/`，避免 macOS 与 Linux 共用平台相关缓存。即使未安装 JDK 或 Maven，这两个缓存挂载仍会创建，不影响核心 CLI。长期容器没有这两个专门挂载，Maven / Gradle 使用机内用户自己的目录（位于系统盘）。

启用代理时，临时容器的入口脚本会为 Gradle 添加带标记的代理配置块；Maven 的 `settings.xml` 不存在或原本由 ai-box 管理时，才会写入代理配置，不覆盖用户自有的文件。切回直连后，入口脚本只移除自己管理的内容并保留其他配置。普通 Java 程序通常不读取 `HTTP_PROXY`；代理模式下直连会被防火墙拒绝，需要显式传入 JVM 参数：

```bash
java -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=8080 \
     -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=8080 \
     -jar app.jar
```

## 更新

长期容器有自己的可写系统盘，创建后不会随镜像更新，CLI 直接在系统盘里升级：

```bash
aibox update           # Claude Code 和 Codex
aibox update cc        # 仅 Claude Code
aibox update codex     # 仅 Codex
```

`aibox update` 先读取长期容器里已安装的版本，再从 npm 镜像（npmmirror）查询最新版本，逐个显示 `当前 -> 最新`，等待 `[y/N]` 确认后才在机内安装；没有可用更新时直接结束。安装使用机内本地 gost 代理（如已配置），不改写 `Dockerfile` 版本钉。`aibox version [cc|codex]` 显示机内实际安装的版本。

临时容器使用基础镜像，更新的是镜像：

```bash
aibox tmp update           # Claude Code 和 Codex
aibox tmp update cc        # 仅 Claude Code
aibox tmp update codex     # 仅 Codex
```

`aibox tmp update` 从 npm 镜像查询版本，显示差异并等待确认；确认后会修改 `Dockerfile` 中的锁定版本，然后用 `Dockerfile.update` 做**增量更新**：在现有镜像之上只叠一层 `npm install`，只下载本次有更新的包，不重跑 apt/locale/pip 等旧层，也不依赖 builder 的层缓存（builder 删除重建后缓存会全丢，全量构建就得重下所有依赖）。若本地没有镜像或增量构建失败，会提示回退全量构建。新的临时容器使用新镜像，已经运行的容器不受影响。增量更新每次都会给镜像叠加一层新 layer（旧版本文件仍留在下层），多次更新后镜像会缓慢变大，可用 `aibox tmp build` 全量重建压平——`tmp update` 已同步改写 `Dockerfile` 的版本 ARG，全量重建得到的版本与增量结果一致。

重建与同步规则：

- 修改 `Dockerfile`、`network-lockdown.sh`、`LOCALE_GEN` 或已识别的 `third_party` 文件后运行 `aibox build`（依次构建基础镜像和长期容器镜像）；只用临时容器时 `aibox tmp build` 即可。
- `aibox build` 不会替换已创建的长期容器：它继续使用自己的系统盘。要整体换用新镜像（例如修改了 `Dockerfile.dev`），先备份系统盘里需要保留的内容，再 `aibox delete` 并运行 `aibox` 重新创建。宿主 Home 中的文件不会随长期容器删除。
- 仓库在宿主 Home 内时，每次启动长期容器都会先以 root 把仓库里的辅助脚本（`dev-profile.sh`、`dev-shell.sh`、`dev-configure.sh`、`dev-proxy-run.sh`、`dev-tools.sh`、`aibox-dev-proxy.service`）和 `third_party/gost` 同步进已有的长期容器，因此修改这些文件后无需重建，下次启动即生效。仓库不在 Home 内时机内看不到它，启动器会提示跳过同步；此时需要 `aibox build` 后 `aibox delete` 并重新创建。
- 修改 `aibox.conf` 或宿主端 `ai-box` 后下次启动即可生效；普通 `entrypoint.sh` 修改也会通过快照对临时容器生效，但涉及镜像工具、用户或权限模型时仍须全量重建。

本次引入强制代理防火墙后必须至少执行一次 `aibox build`：旧镜像没有 iptables、专用 gost 用户和 root 初始化入口，不能只靠运行时 entrypoint 快照升级。

## 排障

| 现象 | 处理 |
|---|---|
| 不确定哪一步没配好 | 运行 `aibox setup --check`（还没有 `aibox` 命令时用仓库里的 `./setup.sh --check`）逐项检查，再运行 `aibox setup` 按提示补齐 |
| 找不到 `container` | 安装或升级 Apple container，并确认其命令在 `PATH` 中 |
| 服务未启动 | 进入长期容器的命令会自动启动服务；临时容器和 `aibox build` 不会，先运行 `container system start`（或 `aibox start`，它同时会创建/启动长期容器），再用 `aibox status` 检查 |
| `aibox` 提示找不到长期容器镜像 | 运行 `aibox build`，它会依次构建基础镜像和长期容器镜像 |
| `aibox tmp` 提示找不到镜像 | 运行 `aibox build`（或只构建基础镜像的 `aibox tmp build`） |
| `aibox` 提示目录不在宿主 Home 内 | 长期容器只挂载宿主 Home；Home 外的目录改用 `aibox tmp /path` |
| 提示仓库不在宿主 Home 内、辅助脚本无法自动同步 | 把仓库移到 Home 内；或 `aibox build` 后 `aibox delete` 并重新创建长期容器 |
| 升级后启动时询问如何迁移旧数据 | 预期行为，只会出现一次：选择用长期容器的、临时容器的或合并；暂时不想处理就选「稍后再说」，之后运行 `aibox migrate` |
| 迁移后发现少了某些设置或会话 | 迁移时还在运行的会话会继续写旧目录。对照机内 `~/.claude.pre-aibox-<时间>/` 或 `~/.aibox/legacy/` 里的备份手动补回 |
| 重启 Mac 后首次运行 `aibox` 提示 `Failed to connect to bus` | 更新宿主端 `ai-box`；启动器会等待机内 systemd manager 就绪后再刷新系统配置，现有长期容器无需删除 |
| builder 报 `-9816: server closed session` | 运行 `container builder delete --force`，然后重新构建 |
| 配置代理后提示缺少 gost | 放入 `third_party/gost`：临时容器需 `aibox build` 重建；长期容器在仓库位于 Home 内时下次启动自动同步。或将 `AIBOX_PROXY` 设为空 |
| 提示缺少强制代理组件或防火墙初始化失败 | 运行 `aibox build` 全量重建；仍失败时检查 Apple container 是否接受启动器传入的 `CAP_NET_ADMIN`；可用 `aibox tmp logs <目标>` 看启动日志 |
| `socks5://` 下域名解析失败 | 尝试 `socks5h://`，让上游解析域名 |
| locale 回退到 `C.UTF-8` | 将 locale 加入 `LOCALE_GEN` 后重建 |
| `mvn` 提示找不到 Java | 同时提供 `jdk8.tar.gz`，或自行安装兼容 JDK |
| 长会话卡顿或被 OOM 终止 | 结束并恢复会话；临时容器按主机容量调整 `MEMORY`，长期容器用 `aibox set memory=...` 后 `aibox restart` |
| 同名项目的 Claude 状态混合 | 使用不同的目录 basename |
| 构建无法下载 APT/PyPI/npm 依赖 | 检查 builder 网络和 DNS；本地三方包不会替代这些在线依赖 |
| 挂载的项目目录在临时容器内为空 | Apple container 的单文件挂载会连带共享其父目录；父目录若同时是另一挂载的源（如挂载沙箱仓库自身时的 `entrypoint.sh`），该目录会静默挂空。`ai-box` 已改挂 entrypoint 启动时快照规避；仍出现则更新宿主端 `ai-box` 或重启 container 服务 |

日志中可能出现项目路径、代理主机或工具输出。提交问题前请删除 API key、代理账密、token 及业务数据。

## 开发、贡献与问题报告

提交改动前至少运行：

```bash
bash -n ai-box setup.sh entrypoint.sh ai-box-completion.sh
shellcheck ai-box setup.sh entrypoint.sh ai-box-completion.sh  # 已安装 ShellCheck 时
aibox build                                          # 有 Apple container 环境时；依次构建基础镜像和长期容器镜像
```

可选组件相关改动应额外验证空 `third_party/`、单独每个组件及所需组合。涉及用户行为时，请同步更新中文和英文 README。普通缺陷和功能请求请通过 GitHub Issues 提交，并附上脱敏后的 macOS、Apple container、`aibox status` 和复现信息。

安全漏洞请优先使用仓库的 GitHub Security Advisory 私密报告入口。若该入口尚未启用，只提交不含利用细节和秘密的最小公开 Issue，请维护者建立私密沟通渠道；不要公开有效凭据、代理账号或未修复漏洞细节。

## 卸载

先结束容器，再删除镜像、软链和仓库：

```bash
aibox tmp stop --all
aibox tmp clear
aibox delete
container image delete ai-sandbox:latest
container image delete ai-sandbox-dev:latest
rm "$HOME/.local/bin/aibox"
```

最后删除克隆目录。删除仓库会删除 Gradle 缓存（`cache/gradle`）；登录状态在宿主 `~/.aibox`，不随仓库删除，按需备份或手动删除。宿主机的 `~/.m2/repository` 不会随仓库删除。若 shell 配置中加入了补全或 `PATH` 行，也请一并移除。

## 许可证与第三方软件

本项目代码按 [MIT License](LICENSE) 发布。可选的 gost、Temurin 和 Maven，以及基础镜像、系统包、Claude Code、Codex CLI 和 `ai-ipcheck`，均由各自作者按各自许可证或服务条款提供，不因本仓库的 MIT License 而改变。下载、使用或重新分发前，请查阅上游许可、NOTICE 和条款。
