# 更新日志

本项目遵循[语义化版本](https://semver.org/lang/zh-CN/)。1.0 之前，次版本号的变化可能包含不兼容的改动，升级前请先看对应版本的「升级须知」。

`aibox --version` 显示当前安装的版本。

## [0.4.0] - 2026-10-30

新增 Mac 应用控制（computer use）：容器里的 Claude Code / Codex 可以在后台操作 Mac 上你批准的应用。

English summary: new `aibox cu` command for Mac app control (computer use). It installs the open-source CuaDriver (trycua/cua, pinned version, SHA-256 and Team ID checked, telemetry and update checks off), runs a gateway LaunchAgent on the Mac, and registers an MCP server named `mac` for Claude Code and Codex in both container types. The first time the AI wants an app, the Mac shows an approval dialog (deny / this session / always); terminals, IDEs, browsers, Finder, System Settings, password managers, scripting tools, remote-control and AI apps are always blocked. The gateway filters tools and arguments, CuaDriver runs in bounded mode limited to approved apps, and only `CuaDriver.app` holds Screen Recording and Accessibility. No image rebuild is needed. The setup wizard gains an optional step 9.

### 新增

- `aibox cu install / status / doctor / apps / allow / revoke / off / on / update / restart / uninstall`。安装会下载 aibox 锁定版本的 CuaDriver（约 85 MB），校验 SHA-256 和签名的 Team ID，引导给它授权辅助功能和屏幕录制，启动网关并在 `~/.aibox/claude`、`~/.aibox/codex` 里注册 `mac` 服务。详见 [`computer-use/README.md`](computer-use/README.md)。
- AI 第一次使用某个应用时，Mac 上弹出确认框（拒绝 / 仅本次会话 / 总是允许）。工具调用本身默认放行，确认框是唯一的人工关口。
- 终端、IDE 等开发工具、浏览器、访达等系统外壳、系统设置、密码类、脚本与启动器、远程控制、AI 应用一律禁止控制，清单写死在代码里。
- 网关检查每次调用：只开放 28 个工具，每个工具的参数和 MCP 方法也是白名单；每个操作的目标 pid 必须属于本会话授权的应用（「仅本次会话」的授权别的会话用不了）；`launch_app` 只能用已授权应用的 bundle id，不能带要打开的文件或 URL；不开放前台模式和往宿主机写文件的参数；`run_steps` 逐步检查。只认 `/Applications` 和系统目录里安装的应用，防止伪造应用包骗过确认框。CuaDriver 以 bounded 模式运行，只能碰已授权的应用，不能全屏截图或按桌面坐标操作。审计日志在 `~/Library/Logs/aibox-cu/audit.log`。
- 支持 MCP 的旧协议和无状态的新协议（2026-07-28）。
- 不需要重建镜像：临时容器挂上转发器的快照，并以环境变量拿到网关的 token 和端点（token 的值不出现在 `container` 的参数里）；代理模式下入口脚本只为网关的这一个端口给防火墙开口子。长期容器在每次启动时同步转发器。
- `aibox status` 新增「应用控制」一行；安装向导新增可选的第 9 步；`aibox.conf` 新增 `AIBOX_CU_PORT`（默认 47123），重跑向导时保留原值。

### 升级须知

- 不启用就和以前一样。启用需要命令行工具（CLT）自带的 `/usr/bin/python3`。

## [0.3.2] - 2026-10-26

本版的修复大多来自 [@rezicwu-sketch](https://github.com/rezicwu-sketch) 在多人共用 Mac mini 的环境中发现并提交的补丁。

English summary: the persistent container now releases its cached host files every time they pass 50,000 (checked every 2 seconds); each cached file pins an open handle on the Mac, and a large walk could exhaust the Mac's system-wide file table and make it reboot. Temporary containers that mount the whole home directory (or a parent of it) no longer use it as the working directory, which made Claude Code walk the home at startup and pinned 100k+ open file handles on the Mac per container; `aibox tmp cc` passes the mount to Claude Code with `--add-dir`. Closing the terminal or dropping an SSH session now stops the temporary container instead of leaving it running. The in-container Claude Code auto-updater is disabled, and the IPv6 sysctl no longer prints "Read-only file system" at startup.

### 修复

- 长期容器新增常驻服务 `aibox-dev-cache-trim`：每 2 秒检查一次机内缓存的宿主机文件数，超过 5 万就释放缓存。宿主机为长期容器缓存过的每个文件都保留一个打开的句柄，机内不缺内存就不会主动释放；在挂载的家目录里做大范围遍历每秒能缓存一两万个文件，不到一分钟就能占满整个 Mac 共用的约 49 万个句柄，系统进程随之崩溃、Mac 自动重启。实测 10 万个文件的并行遍历中，句柄峰值只比平时多 4.4 万。被释放的文件下次访问稍慢；`sudo journalctl -u aibox-dev-cache-trim` 可以看到每次释放的记录。服务随启动同步装进已有的长期容器，无需重建。
- 临时容器的挂载目录包含整个家目录（在 `~` 下运行 `aibox tmp cc`，或挂载 `/Users`、`/`）时，工作目录改为空目录 `~/.aibox/home-workdir`，挂载内容仍在 `/workspace/<项目名>` 下。原先 Claude Code 一启动就会遍历整个家目录，宿主机为此给单个容器保留十几万个打开的句柄，同时开几个容器会耗尽内核内存，导致 Mac 大量杀进程甚至自动重启。实测改用空目录后约 2 千。`aibox tmp cc` 会自动加上 `--add-dir /workspace/<项目名>`，家目录里的文件不用逐个确认权限；进入 shell 时会提示手动运行 `claude` 时同样加上这个参数。
- 关闭终端标签页或 SSH 断开时，启动器会停掉自己的临时容器；以前容器会以无人连接的状态留在后台继续占内存。用 `ssh 主机 "aibox tmp ..."` 直接执行命令再断开的情况仍不能自动处理，见 README「排障」。
- 关闭容器内 Claude Code 的自动更新（临时容器传入、长期容器在 profile 里导出 `DISABLE_AUTOUPDATER=1`）。CLI 由 root 安装在 `/usr/local`，容器内的用户没有写权限，自动更新只会显示 "Auto-update failed"；升级仍用 `aibox tmp update` / `aibox update`。
- `/proc/sys` 只读时，入口脚本关闭 IPv6 不再每次打印三行 "Read-only file system"。

## [0.3.1] - 2026-10-23

aibox 定位为通用的 AI CLI 沙箱：镜像不再内置 JDK / Maven，临时容器不再挂载 Maven / Gradle 缓存。安装向导新增容器资源（内存 / CPU）配置，并能清理旧版留下的 JDK、Maven 包和 Gradle 缓存。

English summary: aibox is now a general-purpose AI CLI sandbox. The image no longer installs the optional JDK 8 / Maven archives, and temporary containers no longer mount `~/.m2/repository` or a Gradle cache. New `AIBOX_MEMORY` / `AIBOX_CPUS` settings in `aibox.conf` control container resources (every temporary container, and the persistent container when it is first created); the setup wizard asks for them, checks them against the Mac, and offers to apply changes to an existing persistent container with `aibox set`. The wizard also offers to delete the old JDK / Maven archives and Gradle cache, and its questions are now arrow-key menus, with common values plus a manual-entry item for time zone, language, memory and CPU. The confirmations and choices in `aibox` itself use the same menus (shared `aibox-ui.sh`); piped input still takes numbers and y/n.

### 升级须知

- **镜像不再内置 JDK / Maven**：下次 `aibox build` 后，新镜像里没有 `/opt/java/jdk8`、`/opt/maven`。已创建的长期容器继续用自己的系统盘，旧镜像带来的这两个目录还在，但不再自动设置 `JAVA_HOME` / `MAVEN_HOME`、不再加入 `PATH`。需要 Java 时在长期容器里用 `sudo apt-get install` 安装（见 README「开发工具链」）。
- **临时容器不再挂载 Maven / Gradle 缓存**：宿主机的 `~/.m2/repository` 不再挂进去；`~/.aibox/cache/gradle` 不再使用。代理模式下也不再自动生成 Maven `settings.xml` / Gradle `gradle.properties` 里的代理配置。
- **旧文件可以清理**：`~/.aibox/third_party/` 里的 `jdk8.tar.gz`、`maven.tar.gz`，以及 `~/.aibox/cache/gradle` 都不再使用。运行一次 `aibox setup`，第 6 步会列出它们的大小并询问是否删除（默认不删）。
- 资源默认值不变（内存 8192M，CPU 由 container 决定），不配置就和以前一样。
- 不重建镜像也能用；重建后镜像会小一些。

### 新增

- `aibox.conf` 新增 `AIBOX_MEMORY`、`AIBOX_CPUS`，同名的非空环境变量可以临时覆盖。临时容器每次启动时使用；长期容器只在首次创建时使用，之后仍用 `aibox set` 调整。格式不对时直接报错，不启动容器。
- 安装向导第 1 步显示本机内存和 CPU 核数；第 5 步新增「资源」一节，不允许超过本机，修改后如果长期容器已存在，会询问是否用 `aibox set` 同步。
- 安装向导第 6 步检查旧版的 JDK / Maven 包和 Gradle 缓存，询问是否删除。
- `aibox status` 显示资源配置。
- 安装向导的选择题改为 ↑↓ 选择、回车确认，是 / 否也可以直接按 y、n。时区、语言、内存、CPU 列出常用选项，另有「手动输入…」填其他值；已配置的代理地址和 API key 可以选择沿用、换新值或删除。文字输入支持左右移动光标修改。`aibox` 命令里的确认和选择（迁移方式、`aibox tmp enter` 不带参数时选容器、删除 / 停止 / 更新前的确认）也改成同样的菜单，两者共用新增的 `aibox-ui.sh`。输入不是终端时（管道、脚本）仍按编号和 y/n 读取，读到输入结束按默认处理（`aibox` 的确认默认为否）。

### 修复

- 安装向导的代理连通测试改为不带 key 请求 `https://api.anthropic.com/v1/models`，只有收到 Claude API 自己的 401（`authentication_error`）才算接通。以前请求根路径，任何 HTTP 状态码（包括 404）都算通，代理或中间设备返回的拦截页也会被误判为可用。返回 403 时会提示出口 IP 所在地区可能不受支持。
- 代理是 `socks5://` 时，连通测试改由代理端解析域名，和容器里 gost 的实际行为一致。以前 Mac 上开着 fake-ip 模式的代理软件时，本机会把域名解析成 `198.18.x.x` 假地址，测试因此超时，其实容器里能正常用。

### 移除

- `~/.aibox/third_party/` 里的 `jdk8.tar.gz`、`maven.tar.gz` 不再进入构建上下文，镜像也不再安装它们；首次运行时也不再从程序目录搬迁它们和 Gradle 缓存。
- 临时容器的 `~/.m2/repository`、Gradle 缓存挂载，以及入口脚本为 Maven / Gradle 生成代理配置的逻辑。

## [0.3.0] - 2026-10-22

支持通过 Homebrew 安装：`brew install simpletang/tap/aibox`，然后运行 `aibox setup`。

English summary: aibox can now be installed with Homebrew (`brew install simpletang/tap/aibox`, then `aibox setup`). The setup wizard recognizes Homebrew installs, removes a shadowing `~/.local/bin/aibox` left by a git clone, and points completion at the version-independent `opt/aibox` path. Releases update the tap's formula automatically.

### 升级须知

- git 克隆用户照常 `git pull` 即可，无需其他操作。
- 想改用 Homebrew：`brew install simpletang/tap/aibox` 后运行一次 `aibox setup`，它会提议删除旧的 `~/.local/bin/aibox` 软链接，并把 Tab 补全改到 Homebrew 的路径（旧的补全行会被注释掉，不删除）。用户数据已经在 `~/.aibox`，确认无误后可以删除原来的克隆目录。
- 不需要重建镜像。

### 新增

- Homebrew tap：`simpletang/tap`。配方不声明 Apple container 依赖，由 `aibox setup` 引导安装已验证的版本，避免和已用 `.pkg` 安装的 container 冲突。
- 发布工作流在创建 Release 后自动更新 tap 里的配方：用只对 tap 仓库有写权限的 deploy key 推送（私钥存为仓库密钥 `HOMEBREW_TAP_DEPLOY_KEY`；未配置时跳过，不影响发布）。
- `aibox --version` 会标出 Homebrew 安装。

### 变更

- 安装向导第 4 步识别 Homebrew 安装：不再创建 `~/.local/bin/aibox`，改为检查它是否被之前 git 克隆留下的软链接挡住并提议删除；Tab 补全使用不随版本变化的 `opt/aibox` 路径。shell 配置里指向别处的补全行会被注释掉（git 克隆搬家后也适用）。
- `aibox help` 里的补全路径对 Homebrew 安装同样使用 `opt/aibox`。

## [0.2.0] - 2026-10-22

用户数据和状态统一放进 `~/.aibox/`，程序目录（git 克隆，或今后的 Homebrew 安装目录）只读、可以整体替换。这是打包成 Homebrew 的前提，也让 `git pull` 升级不再和本地改动冲突。

English summary: all user data now lives in `~/.aibox/` (config, optional third_party assets, Gradle cache, CLI version pins, staged machine helpers), so the program directory is read-only and replaceable. Existing files are moved automatically on first run. `aibox tmp update` no longer edits the Dockerfile, builds use a staged context, the persistent container no longer requires the clone to be inside your home, and aibox now refuses to run outside macOS or as root.

### 升级须知

- **首次运行会自动搬家**：程序目录里的 `aibox.conf`、`third_party/` 里的 gost / JDK / Maven、`cache/gradle` 会被移到 `~/.aibox/` 下，并打印一行说明。原来的 `aibox.conf` 位置会留下一个指向新位置的软链接，照旧编辑那里也行。Gradle 缓存只在没有临时容器运行时才搬，否则下次再搬。
- **用旧版 `aibox tmp update` 升级过 CLI 的**：如果 `Dockerfile` 的本地改动只有那两行版本号，会被提取到 `~/.aibox/versions.env`，并用 git 还原 `Dockerfile`；有其他改动则保持原样，需要自己处理。
- **剪贴板贴图**：升级后运行一次 `aibox clip restart`，监听脚本会改为从 `~/.aibox/clipboard/` 运行，以后更换程序目录也不受影响。
- **不需要重建镜像**，镜像配方没有变化。

### 新增

- `~/.aibox/versions.env`：`aibox tmp update` 确认后的 CLI 版本记在这里，构建时以 `--build-arg` 覆盖 `Dockerfile` 里的默认值；两者取较新的一个。`aibox tmp version` 会标出来自这里的版本。
- `aibox` 拒绝在 macOS 以外的系统上、或以 root 身份运行（`help` 与 `--version` 除外）：在 Linux 容器里或 `sudo` 下，`$HOME` 指向的不是 Mac 用户的 Home。

### 变更

- 配置改为 `~/.aibox/aibox.conf`，`aibox setup` 也写到这里。
- 可选组件改放 `~/.aibox/third_party/`。构建时在临时目录里组装上下文：程序文件按 `.dockerignore` 白名单从程序目录取，第三方组件从 `~/.aibox` 取（APFS 上用写时复制的克隆，大文件不占时间和空间），构建完即删除。
- 临时容器的 Gradle 缓存改为 `~/.aibox/cache/gradle`。
- `aibox tmp update` 不再修改 `Dockerfile`。
- 长期容器的辅助脚本先暂存到 `~/.aibox/machine/` 再同步，程序目录不再需要放在 Home 内；gost 从 `~/.aibox/third_party/gost` 同步。
- 剪贴板监听脚本在 `aibox clip install` 时复制到 `~/.aibox/clipboard/`，launchd 指向这份副本；`aibox clip uninstall` 一并删除。
- `aibox build` / `aibox tmp build` 的附加参数排在版本参数之后，自己传的同名 `--build-arg` 会生效。
- 程序目录里还留着已搬走的 `aibox.conf`、`third_party` 文件或 Gradle 缓存时，运行时会提示旧的那份已不再使用。

### 修复

- 发布说明开头多出的空行。

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
