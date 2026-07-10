# ai-sandbox

[中文](README.md) | [English](README.en.md)

在 Apple silicon Mac 上通过 [Apple container](https://github.com/apple/container) 运行 Claude Code 和 Codex CLI 的轻量开发沙箱。每次启动都会创建一个临时 Linux 容器，只挂载当前项目及明确列出的持久化目录；代理、时区和语言均为运行期可选配置。

本项目是社区项目，与 Apple、Anthropic 或 OpenAI 无隶属或背书关系。Claude、Claude Code、OpenAI 和 Codex 等名称及商标归其各自权利人所有。使用相关服务时，请遵守对应条款和当地法律。

## 功能

- 一条 `aibox` 命令进入 shell，或直接启动 `claude` / `codex`。
- 每个终端会话使用独立的 `--rm` 容器，支持多个项目并行运行。
- 项目文件、Claude/Codex 登录状态及构建缓存按明确规则持久化。
- 默认直连；也可通过可选的 gost 连接 HTTP、HTTPS、SOCKS5 或 SOCKS5H 上游代理。
- 时区和 locale 可跟随宿主机，也可逐次或通过配置文件指定。
- 镜像默认安装 `ai-ipcheck`，可直接使用 `ipcheck` 诊断容器网络环境。
- 提供容器列表、进入、停止、日志、状态、CLI 更新及 Tab 补全。
- `third_party/` 中的 gost、JDK 8 和 Maven 均为独立可选组件。

## 兼容性

| 项目 | 要求或当前配置 |
|---|---|
| 主机 | Apple silicon Mac |
| 操作系统 | macOS 26 或更高版本 |
| 容器运行时 | Apple container（已在 CLI 1.0.0 验证；不是 Docker） |
| 宿主脚本 | 兼容 macOS 自带 Bash 3.2；日常可从 zsh 调用 |
| 容器架构 | Linux ARM64，基础镜像为 `node:22-bookworm` |
| 单容器内存 | 默认 `8192M`；可在 `ai-box` 的 `MEMORY` 变量中调整 |

构建仍会联网下载基础镜像、APT/PyPI 包以及 Claude Code/Codex npm 包。`third_party/` 可为空并不表示镜像支持完全离线构建。

## 安装

先按 Apple container 的官方说明安装并确认 `container` 命令可用，然后克隆本仓库。仓库可以放在任意路径；`ai-box` 会根据脚本自身位置定位构建文件。

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
aibox build

cd /path/to/your-project
aibox cc       # 启动 Claude Code
aibox codex    # 启动 Codex CLI
aibox          # 只进入 shell
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

自定义值不会出现在 `container` CLI 的命令行参数中，也不会导出到宿主机 `ai-box` 进程环境，因此自定义 `PATH`、`HOME` 等名称不会改变宿主启动器的环境。启动器会把值短暂写入宿主机上权限为 `0600` 的临时 env-file，并在正常退出或收到常见终止信号时清理；系统崩溃或强制 `SIGKILL` 仍可能留下临时文件。值会作为环境变量对容器进程可见，所以这不构成秘密隔离。`ai-box` 不再隐式透传宿主机环境中的 `ANTHROPIC_API_KEY`、`OPENAI_API_KEY` 或其他 API key；需要传入的每个变量都必须显式列入 `AIBOX_ENV_VARS`。

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
支持代理环境变量的进程
  -> http://127.0.0.1:8080
  -> gost
  -> AIBOX_PROXY 指定的上游
```

入口脚本会设置大小写形式的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 和 `NO_PROXY`。`socks5h://` 由代理端解析域名，适用于本地 DNS 不可用或不应参与解析的场景。代理地址及账密会在启动横幅中脱敏显示。

这不是网络 kill switch。只有遵循这些环境变量或对应配置的程序才会使用代理；原始 socket、部分 Java 程序及主动忽略代理变量的程序仍可能直连。项目没有防火墙级的强制路由保证，请根据自己的威胁模型独立验证网络路径。

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

## 安全与信任边界

容器不是“只能访问当前项目”的绝对安全边界。每次运行会显式提供以下宿主机资源：

| 宿主机资源 | 容器路径 | 用途 |
|---|---|---|
| 选定的项目目录 | `/workspace/<项目名>` | 项目读写 |
| `<仓库>/creds/claude` | `/home/node/.claude` | Claude 登录、配置及项目状态 |
| `<仓库>/creds/codex` | `/home/node/.codex` | Codex 登录及配置 |
| `~/.m2/repository` | `/home/node/.m2/repository` | Maven 依赖缓存 |
| `<仓库>/cache/gradle` | `/home/node/.gradle` | Linux 专用 Gradle 缓存和配置 |
| `<仓库>/entrypoint.sh` | `/usr/local/bin/entrypoint.sh` | 只读的运行期入口脚本 |

除入口脚本外，这些目录用于持久化读写。容器中的 AI 工具及其子进程能够读取或修改它们，项目文件的修改会立即反映到宿主机。不要为不可信代码挂载含敏感内容的项目，也不要把秘密放进 Maven/Gradle 缓存。

此外还应了解：

- `AIBOX_ENV_VARS` 中的值不会放入 `container` CLI 参数或导出到宿主启动器环境；它们会短暂存放在权限为 `0600`、由 `ai-box` 在正常退出和常见终止信号下清理的宿主机临时 env-file 中，并作为环境变量对容器进程可见。
- 容器以 `node` 用户运行，但该用户拥有容器内的免密 `sudo`；容器内提权后仍可操作已挂载资源。
- `--rm` 只删除临时容器文件系统，不删除项目、凭据和缓存。
- 项目名取自目录 basename；不同路径下的同名项目会得到相同容器工作路径，并可能共享 Claude 的项目状态。需要严格隔离时请使用不同目录名和独立凭据目录。
- 容器降低误触宿主机其他路径的风险，但不能替代代码审查、最小权限、秘密管理或容器运行时安全更新。

## 命令

```bash
# 新建临时容器
aibox [/path/to/project]             # 进入 shell，默认挂载当前目录
aibox cc [/path/to/project]          # 启动 Claude Code
aibox codex [/path/to/project]       # 启动 Codex CLI

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
aibox build [--no-cache]              # 构建镜像
aibox update [cc|codex]               # 检查版本，确认后修改 Dockerfile 并重建
aibox version                         # 显示 Dockerfile 中锁定的 CLI 版本
aibox status                          # 显示服务、镜像、锁定版本和运行中容器
aibox help                            # 命令帮助
```

`enter`、`stop` 和 `logs` 使用同一套目标解析规则。编号来自当前的 `aibox list`，容器增减后应重新查看列表。`version` 和 `status` 中的 CLI 版本来自当前仓库的 `Dockerfile`，不保证与此前构建或正在运行的镜像完全一致。

## Java 与构建缓存

Java 支持完全可选：

- 放入 `jdk8.tar.gz` 后提供 `java`、`javac` 和 `JAVA_HOME`。
- 放入 `maven.tar.gz` 后提供 `mvn` 和 `MAVEN_HOME`；Maven 自身仍需要 JDK。
- Gradle 不内置发行版，项目可使用 `./gradlew`；它同样需要可用的 JDK。

Maven 仓库从宿主机 `~/.m2/repository` 挂载，宿主机与容器同时写入时可能发生并发冲突。Gradle 使用仓库下独立的 `cache/gradle/`，避免 macOS 与 Linux 共用平台相关缓存。即使未安装 JDK 或 Maven，这两个缓存挂载仍会创建，不影响核心 CLI。

启用代理时，入口脚本会为 Gradle 添加带标记的代理配置块；Maven 的 `settings.xml` 不存在或原本由 ai-box 管理时，才会写入代理配置，不覆盖用户自有的文件。切回直连后，入口脚本只移除自己管理的内容并保留其他配置。普通 Java 程序通常不读取 `HTTP_PROXY`，需要时请显式传入 JVM 参数：

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

更新命令从 npm 镜像查询版本，显示差异并等待确认；确认后会修改 `Dockerfile` 中的锁定版本并重建镜像。新容器使用新镜像，已经运行的容器不受影响。修改 `Dockerfile`、`LOCALE_GEN` 或已识别的 `third_party` 文件后，也需要运行 `aibox build`。修改 `aibox.conf`、宿主端 `ai-box` 或运行时挂载的 `entrypoint.sh` 后，下次启动容器即可生效。

## 排障

| 现象 | 处理 |
|---|---|
| 找不到 `container` | 安装或升级 Apple container，并确认其命令在 `PATH` 中 |
| 服务未启动 | 运行 `aibox start`，再用 `aibox status` 检查 |
| builder 报 `-9816: server closed session` | 运行 `container builder delete --force`，然后重新构建 |
| 配置代理后提示缺少 gost | 放入 `third_party/gost` 并重建，或将 `AIBOX_PROXY` 设为空 |
| `socks5://` 下域名解析失败 | 尝试 `socks5h://`，让上游解析域名 |
| locale 回退到 `C.UTF-8` | 将 locale 加入 `LOCALE_GEN` 后重建 |
| `mvn` 提示找不到 Java | 同时提供 `jdk8.tar.gz`，或自行安装兼容 JDK |
| 长会话卡顿或被 OOM 终止 | 结束并恢复会话，或按主机容量调整 `MEMORY` |
| 同名项目的 Claude 状态混合 | 使用不同的目录 basename，或为实例拆分凭据目录 |
| 构建无法下载 APT/PyPI/npm 依赖 | 检查 builder 网络和 DNS；本地三方包不会替代这些在线依赖 |

日志中可能出现项目路径、代理主机或工具输出。提交问题前请删除 API key、代理账密、token 及业务数据。

## 开发、贡献与问题报告

提交改动前至少运行：

```bash
bash -n ai-box entrypoint.sh ai-box-completion.sh
shellcheck ai-box entrypoint.sh ai-box-completion.sh  # 已安装 ShellCheck 时
aibox build                                          # 有 Apple container 环境时
```

可选组件相关改动应额外验证空 `third_party/`、单独每个组件及所需组合。涉及用户行为时，请同步更新中文和英文 README。普通缺陷和功能请求请通过 GitHub Issues 提交，并附上脱敏后的 macOS、Apple container、`aibox status` 和复现信息。

安全漏洞请优先使用仓库的 GitHub Security Advisory 私密报告入口。若该入口尚未启用，只提交不含利用细节和秘密的最小公开 Issue，请维护者建立私密沟通渠道；不要公开有效凭据、代理账号或未修复漏洞细节。

## 卸载

先结束容器，再删除镜像、软链和仓库：

```bash
aibox stop --all
aibox clear
container image delete ai-sandbox:latest
rm "$HOME/.local/bin/aibox"
```

最后删除克隆目录。删除前按需备份 `creds/`；删除仓库也会删除容器专用登录状态和 Gradle 缓存。宿主机的 `~/.m2/repository` 不会随仓库删除。若 shell 配置中加入了补全或 `PATH` 行，也请一并移除。

## 许可证与第三方软件

本项目代码按 [MIT License](LICENSE) 发布。可选的 gost、Temurin 和 Maven，以及基础镜像、系统包、Claude Code、Codex CLI 和 `ai-ipcheck`，均由各自作者按各自许可证或服务条款提供，不因本仓库的 MIT License 而改变。下载、使用或重新分发前，请查阅上游许可、NOTICE 和条款。
