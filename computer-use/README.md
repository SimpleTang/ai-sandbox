# Mac 应用控制（computer use）

`aibox cu install` 之后，容器里的 Claude Code 和 Codex 会多一个名为 `mac` 的 MCP 服务。它们可以截取 Mac 上应用的窗口、读取界面元素、点击和输入，用来测试自己写的 Mac 应用、操作只有图形界面的工具，或者跨应用完成一件事。默认在后台操作，不抢你的鼠标和键盘焦点。

Claude 桌面端和 Codex（ChatGPT 桌面端）的 computer use 只在 Mac 本机运行，容器里的 CLI 用不了：macOS 只把屏幕录制和辅助功能权限授给 GUI 会话里获得授权的应用，容器里的进程拿不到。aibox 的做法是在 Mac 上常驻一个网关，容器经它使用开源的 [CuaDriver](https://github.com/trycua/cua)（cua-driver-rs，MIT）。

## 快速开始

```bash
aibox cu install       # 在 macOS 上执行一次:装 CuaDriver、引导授权、启动网关、写入 MCP 配置
aibox cu status        # 应显示「正常」
```

安装会做这几件事：

1. 下载 aibox 锁定版本的 CuaDriver（约 85 MB），校验 SHA-256 和代码签名的 Team ID，装到 `/Applications/CuaDriver.app`，并关闭它的遥测。
2. 引导你给 CuaDriver 授权：辅助功能、屏幕录制（macOS 26 还会多问一次「直接访问屏幕」）。系统提示「退出并重新打开」时点它。
3. 生成网关的 token，装上网关的 LaunchAgent `com.aibox.cu-gateway`。
4. 在 `~/.aibox/claude`（`.claude.json` 与 `settings.json`）和 `~/.aibox/codex/config.toml` 里注册 `mac` 服务，并放行它的工具调用。

装好后重启正在运行的 Claude Code / Codex。之后直接用自然语言让它操作某个应用即可，例如「用计算器算 123×4」「在备忘录里新建一条笔记」。AI 第一次用某个应用时，Mac 上会弹出确认框：

- **拒绝**：这次不给。2 分钟内没人点也按拒绝处理。
- **仅本次会话**：只对发起申请的这个 Claude Code / Codex 进程有效，断开即收回；别的容器、别的会话用不了。
- **总是允许**：记进 `~/.aibox/cu/allowed-apps`，以后不再询问。

旧镜像不需要重建：容器侧的转发器 `aibox-mac-mcp` 会在启动容器时放进去（临时容器挂一份快照，长期容器在每次启动时同步）。

需要命令行工具（CLT）自带的 `/usr/bin/python3`（3.9 以上），网关用它运行；没有时 `xcode-select --install`。

## 工作原理

```
容器(aibox / aibox tmp)                 宿主 Mac(GUI 登录会话)
┌──────────────────────┐   TCP + token   ┌──────────────────────────────────────────────┐
│ Claude Code / Codex  │                 │ aibox-cu-gateway(LaunchAgent,Python)          │
│   │ stdio(MCP)       │ 192.168.64.1    │  · 工具白名单、参数检查、审计日志               │
│ aibox-mac-mcp ───────┼────:47123──────▶│  · request_access → Mac 上的确认框              │
└──────────────────────┘                 │  · 管理专用的 bounded 驱动实例                  │
                                         │        │ stdio                                  │
                                         │ cua-driver mcp(每个连接一个)                    │
                                         │        │ unix socket($DARWIN_USER_TEMP_DIR)     │
                                         │ CuaDriver.app 常驻进程(bounded 模式)            │
                                         │  · 只能碰 manifest 里的应用                      │
                                         │  · 持有屏幕录制 / 辅助功能权限                   │
                                         └──────────────────────────────────────────────┘
```

一次工具调用的路径：

1. Claude Code / Codex 以 stdio 启动 `aibox-mac-mcp`。它连上容器网络里宿主机的地址（默认 `192.168.64.1:47123`），第一行发送 token 握手。
2. 网关校验 token，为这个连接起一个 `cua-driver mcp --socket <专用 socket>` 子进程。
3. 每个 `tools/call` 先过网关的检查，通过后才转给驱动；`tools/list` 的回复被过滤成白名单，并加上网关自己的两个工具。
4. 驱动以 bounded 模式运行，按 manifest 再检查一次目标应用，然后通过辅助功能 API 或 ScreenCaptureKit 完成操作，截图和界面元素原路返回。
5. 授权变化时，网关重写 manifest 并重启驱动（运行中的驱动不支持热加载）。受影响的连接会自动重建子进程，之前的 `snapshot_id` / `element_token` 失效，网关在结果里提示 agent 重新读取窗口。

网关、manifest 和 socket 与你自己可能在用的 CuaDriver 默认实例互不干扰：网关用 `open -n` 另起一个实例，socket 和 manifest 放在 `$DARWIN_USER_TEMP_DIR/aibox-cu/`。

网关同时支持 MCP 的旧协议（`initialize`）和无状态的新协议（2026-07-28 起，`server/discover`、每个请求自带 `_meta`、结果带 `resultType`）。

## 安全模型

computer use 能做的事，等于在 Mac 上坐在键盘前的人能做的事，天然跨出了沙箱。aibox 用三层防护把它限制在你批准的应用里：

1. **网关**：工具和 MCP 方法白名单、按工具的参数白名单、应用分级与授权确认、审计日志。每个操作都必须落到一个 pid 上，网关用 `lsappinfo` 查出它属于哪个应用，只放行本会话可用的应用。容器只能连到网关，连不到驱动的 unix socket（跨虚拟机的 socket 连接会被拒绝）。
2. **CuaDriver 的 bounded 模式**：manifest 只列出已授权的应用，`desktop.display: false` 禁止全屏截图和按桌面坐标操作。白名单之外的窗口、进程、坐标输入，以及 `run_steps` 里嵌套的步骤，都由驱动自己拒绝。
3. **macOS 的权限机制**：屏幕录制和辅助功能只授给 `CuaDriver.app`（Developer ID 签名、已公证，Team ID `YCK386LBJ7`）。网关自己没有这两项权限。

### 禁止控制的应用

下面这些应用写死在网关代码里，`aibox cu allow` 和确认框都不能放行：

| 类别 | 例子 | 原因 |
|---|---|---|
| 终端、IDE 等开发工具 | 终端、iTerm2、Ghostty、Warp、VS Code、Cursor、Xcode、JetBrains 全家；以及所有声明为 `public.app-category.developer-tools` 的应用 | 能直接在宿主机上执行命令 |
| 脚本与启动器 | 脚本编辑器、Automator、快捷指令、Raycast、Alfred、Keyboard Maestro | 能运行脚本或启动任意程序 |
| 系统外壳 | 访达、程序坞、聚焦、控制中心 | 能打开或执行任意文件（在访达里双击 `.command` 就会执行） |
| 系统设置与系统工具 | 系统设置、活动监视器、磁盘工具、安装器 | 能改权限、装软件、抹盘 |
| 凭据 | 钥匙串访问、密码、1Password、Bitwarden、KeePassXC | 密码 |
| 远程控制 | 屏幕共享、远程桌面、TeamViewer、AnyDesk | 能控制别的机器或被别人控制 |
| AI 应用与驱动自己 | Claude、ChatGPT、Codex、CuaDriver | 能执行命令或放宽权限 |
| 浏览器 | Safari、Chrome、Firefox、Edge、Arc 等 | 登录态、任意网页、链接风险；网页任务请在容器里用无头浏览器 |

完整清单见 `gateway.py` 的 `BLOCKED_BUNDLES`。授权时和每次调用时都会按真实安装的应用复查分类，所以手动往 `allowed-apps` 里写一个 IDE 也不会生效。

只认安装在 `/Applications` 和系统目录（`/System/Applications`、`/System/Library/CoreServices`）里的应用，不接受路径，也不认 `~/Applications`：这些位置都在 Home 之外，容器写不进去。否则 agent 可以在项目目录里伪造一个 `.app`（显示名写「备忘录」、bundle id 写成某个 IDE）骗过确认框。确认框里会显示应用的完整路径。

### 工具白名单

| 类别 | 工具 |
|---|---|
| 观察 | `list_windows`（必须带 `pid`）、`get_window_state`、`zoom`、`verify_state`、`parse_visual_regions`、`get_screen_size`、`check_permissions`、`get_guide` |
| 操作 | `launch_app`（只能用已授权应用的 `bundle_id`）、`bring_to_front`、`set_window_frame`、`invoke_menu`、`click`、`double_click`、`right_click`、`drag`、`type_text`、`press_key`、`hotkey`、`set_value`、`scroll`、`run_steps`（逐步检查；步骤里可以用 `role` / `name` / `nth` 定位元素，不能用 `app` / `window` 按名字指定目标） |
| 会话 | `start_session`、`end_session`、`get_session`、`list_sessions` |
| 网关自己的 | `request_access`、`list_granted_apps` |

其余工具一律隐藏并拒绝，包括 `run_script`、`list_apps`、全屏截图、`get_accessibility_tree`、`kill_app`、`move_cursor`、剪贴板、浏览器、录制与回放、`set_config`、扩展安装、更新检查，以及会隐藏代理光标的 `set_agent_cursor_*`。MCP 方法也是白名单：`prompts/*` 等一律拒绝，`resources/read` 只能读 `skill://cua-driver/` 下的说明文档。

每个工具的参数也是白名单（`gateway.py` 的 `TOOL_ARGS`，按锁定的驱动版本整理），多出来的参数一律拒绝，大小写和驼峰变体也一样。刻意不放行的有：

- `launch_app` 的 `name`、`urls`、`additional_arguments`、`webkit_inspector_port`：能按路径启动、让应用打开任意文件或 URL（例如一个 `.command` 脚本）、开调试端口。驱动的 bounded 模式**不**约束 `launch_app`，这一层完全靠网关。
- 能让驱动往宿主机写文件的参数（`screenshot_out_file`、`debug_image_out`）。参数白名单之外，网关还会在任意层级里拦截像文件路径的参数名。
- 前台模式（`delivery_mode: "foreground"`、`run_steps` 的 `foreground_fallback`）：前台输入可能落到当前前台的应用或系统快捷键上（例如用 ⌘空格 打开聚焦再输入「Terminal」）。
- 按名字指定目标的 `app` / `window`、桌面范围的 `target`：绕开 pid 归属检查。
- `check_permissions` 的 `prompt`：会触发系统授权弹窗。

bounded 模式下，只带 `element_token` 的动作会被驱动当成「桌面范围的输入」拒绝。网关会记下每个快照属于哪个 `pid`，替 agent 补上。

### 工具调用默认放行

Claude Code 的 `settings.json` 放行了 `mcp__mac`，Codex 配置了 `default_tools_approval_mode = "approve"`。唯一的人工关口是 `request_access` 在 Mac 上弹出的确认框：确认框在宿主机上，容器伪造不了。要逐次确认，把这两项删掉即可。

### 残留风险

- **获批的应用能做的事，AI 都能做。** 例如文本编辑可以通过「存储」对话框把文件写到任何地方，包括 `~/Library/LaunchAgents`。只批准完成任务需要的应用，用完用 `aibox cu revoke` 收回。
- **长期容器挂载了整个 Home，并且可写。** 里面的进程本来就能写 `~/Library/LaunchAgents` 等位置并在宿主机上执行代码，所以对长期容器来说，computer use 不是新的逃逸途径。它能改的是 `~/.aibox/cu/allowed-apps`，但改了也只能放宽到禁止清单之外的应用。manifest 和本次会话的授权放在 `$DARWIN_USER_TEMP_DIR`，容器挂载不到。git 克隆到 Home 下时，网关代码本身也在 Home 里；Homebrew 安装时不在。
- **临时容器**只挂载项目目录时，挂不到上面这些路径。token 和端点以环境变量传入，token 的值不出现在 `container` 的参数里；代理模式下，防火墙只给网关的这一个地址和端口开口子。但如果在 `~`、`/Users` 或 `/` 下启动临时容器，挂进去的是整个家目录，风险就和长期容器一样。
- 同一个应用同时被两个会话使用时（例如两个 agent 都在操作计算器），它们会互相打乱对方的界面状态。驱动的白名单是所有在线会话的并集，按会话隔离由网关的 pid 检查保证。
- 屏幕录制和辅助功能权限给了一个第三方程序。aibox 锁定版本、校验 SHA-256 和 Team ID、关闭遥测和自动更新检查，但仍请自行评估 [trycua/cua](https://github.com/trycua/cua)。

## 命令

```bash
aibox cu install       # 安装 / 修复(重复执行是安全的)
aibox cu status        # 状态
aibox cu doctor        # 逐项诊断:python3、签名、遥测、权限、网关、端点、token、MCP 注册、日志
aibox cu apps          # 列出「总是允许」的应用
aibox cu allow 备忘录   # 不经确认框,直接加入「总是允许」(应用名、bundle id 或 .app 路径)
aibox cu revoke 备忘录  # 收回
aibox cu off           # 急停:停掉网关和驱动,容器里的 mac 服务报告不可用
aibox cu on            # 恢复(正在运行的 Claude Code / Codex 需要重启才会重新连上)
aibox cu update        # 升级到 aibox 锁定的 CuaDriver 版本
aibox cu restart       # 重新生成并加载网关(升级 aibox、改端口后用)
aibox cu uninstall     # 卸载;会询问是否删除 token、授权清单和 CuaDriver.app
```

`aibox status` 里有一行「应用控制」。在长期容器里可以用 `aibox-mac-mcp --check` 检查连通性。

端口默认 47123，在 `aibox.conf` 里设 `AIBOX_CU_PORT` 修改，之后运行 `aibox cu restart`。

## 文件

| 路径 | 内容 | 容器能否写入 |
|---|---|---|
| `/Applications/CuaDriver.app` | 驱动，权限挂在它上面 | 不能 |
| `~/.cua-driver/`、`~/Library/Caches/cua-driver/` | 驱动自己的配置和默认实例的 socket | 长期容器能写 |
| `$DARWIN_USER_TEMP_DIR/aibox-cu/` | 网关专用驱动实例的 manifest、socket、pid | 不能 |
| `<程序目录>/computer-use/` | 网关、转发器、安装脚本、LaunchAgent 模板 | Homebrew 安装时不能 |
| `~/.aibox/cu/allowed-apps` | 「总是允许」的应用，一行一个：`bundle_id<TAB>名称` | 长期容器能写 |
| `~/.aibox/cu/client/` | 网关的 token（权限 600）和端点 | 长期容器能写；临时容器以环境变量拿到 |
| `~/.aibox/cu/disabled` | 急停标记 | 长期容器能写 |
| `~/Library/LaunchAgents/com.aibox.cu-gateway.plist` | 网关的 LaunchAgent | 长期容器能写 |
| `~/Library/Logs/aibox-cu/gateway.log`、`audit.log` | 网关日志；审计日志记录每次调用的工具、目标和是否放行（输入的文字只记长度） | 长期容器能写 |
| 镜像里的 `/usr/local/bin/aibox-mac-mcp` | 容器侧转发器 | 不能 |

## 与官方 computer use 的差异

- 没有全屏截图和按桌面坐标操作，只能截取和操作已授权应用的窗口。
- 只有「禁止」和「完整」两级；官方的「浏览器只读」「终端和 IDE 只能点击」两级，aibox 第一版直接禁止。
- 没有前台模式，不接受后台输入的应用（Electron 等）控制不了。
- 只认 `/Applications` 和系统目录里的应用。
- 不能枚举应用（bounded 模式下驱动不允许）；按应用名或 bundle id 申请即可，中文名也认（「备忘录」「计算器」）。
- 不支持锁屏状态下操作。

## 排障

- **`aibox cu status` 显示「还没开始监听」**：容器网络的网卡（`bridge100`）在第一个容器启动后才出现，网关每 5 秒重试一次。启动任意容器后再看。
- **授权卡住不动**：在 Mac 上看是否有 CuaDriver 的窗口或系统弹窗在等你操作；点完「退出并重新打开」后，Ctrl+C 再重跑 `aibox cu install`。`aibox cu doctor` 会检查权限。
- **容器里看不到 `mac` 服务的工具**：先在长期容器里运行 `aibox-mac-mcp --check`。不可用时，服务的说明里会写明原因（没安装、已急停、token 不对、连不上）。改过 token 或重新安装后，要重启 Claude Code / Codex。
- **某个应用的点击没反应**：Electron 等应用不接受后台输入。aibox 不开放前台模式，这类应用目前控制不了。
- **审计**：`tail -f ~/Library/Logs/aibox-cu/audit.log`。

## 升级 CuaDriver（维护者）

`install-host.sh` 顶部锁定了 `CUA_VERSION`、`CUA_SHA256`（darwin-arm64 包）和 `CUA_TEAM`。升级时：

1. 从 [Releases](https://github.com/trycua/cua/releases) 找到 `cua-driver-rs-v<版本>`，下载 `cua-driver-rs-<版本>-darwin-arm64.tar.gz`，对照发布里的 `SHA256SUMS`，再用 `codesign -dv` 确认 Team ID 没变。
2. 改上面三个常量，运行 `aibox cu update`。
3. 检查新版有没有新增工具，需要的话更新 `gateway.py` 的白名单和 `DISABLED_REASONS`；看一遍新增工具里有没有能往宿主机写文件、打开 URL 或执行脚本的参数。
4. 跑下面的验证。

## 验证

`tests/smoke.sh` 覆盖了不依赖 macOS 的部分：网关的策略函数、manifest、MCP 注册、转发器（握手、透传、降级，新旧两种协议），以及 `ai-box` 的接入点（临时容器的挂载和环境变量、长期容器的同步、急停、端口校验、LaunchAgent 模板）。

真机端到端测试（改动网关或升级 CuaDriver 后执行）：

1. `aibox cu install`，然后 `aibox cu doctor` 全部通过。
2. 在长期容器里运行 `claude -p "用 mac 这个 MCP 操作 Mac 上的「计算器」算 123×4，读出结果。然后试着申请控制「终端」，把网关的回复原样告诉我。"`：Mac 上弹出计算器的确认框；结果是 492；终端的申请被拒绝，回复里写明原因。
3. 用 `codex exec` 跑同样的任务。
4. 在 `aibox tmp` 临时容器里运行 `aibox-mac-mcp --check`；配了代理时，再确认直连外网仍被拦截。
5. `aibox cu off` 之后，转发器报告不可用；`aibox cu on` 之后恢复。
6. 看一眼 `audit.log`，拒绝的调用写明了原因。
