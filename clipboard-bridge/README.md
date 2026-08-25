# 剪贴板图片桥接

让沙箱里的 Claude Code 支持用 **Ctrl+V 直接粘贴宿主机 macOS 剪贴板里的图片**。

面向 `aibox` 与 `aibox dev` 两种模式，宿主机侧装一次即可。

---

## 1. 问题

在 macOS 上用终端连进沙箱后：

- **文本能粘贴** —— 这是终端模拟器干的活：它读 macOS 剪贴板，把文本当成键盘输入写进
  tty 字节流。沙箱里的程序只是"收到了一串字符"，完全不知道有过粘贴这回事。
- **图片粘不了** —— tty 是纯字节流，传不了"一张图"。要贴图，必须由**运行中的程序自己
  去读操作系统剪贴板**。而沙箱是独立的 Linux 环境：没有 X11/Wayland，更没有任何通往
  macOS 剪贴板的通路。

### 为什么装 xclip + X11 解决不了

这是最容易踩的弯路。`xclip` 只是客户端，它读的是 X server 里的 CLIPBOARD selection。
在沙箱里起 Xvfb/Xephyr，得到的是一块**全新的、空的**剪贴板 —— 你在 macOS 上 ⌘C
不会有任何东西流进去，两者之间根本没有通路。装完的结果是 `xclip -t TARGETS -o` 返回空，
Claude Code 依旧认为"剪贴板里没有图片"。

唯一"看起来"能打通的是 XQuartz（在 macOS 上跑 X server，沙箱里 `DISPLAY` 指过去），
但它的 pasteboard 同步是**面向文本**的，图片同步不可靠 —— 恰好就是唯一需要的那一半；
何况还要把 X server 暴露到网络上给虚拟机连，安全和复杂度都不划算。

---

## 2. 思路

从 Claude Code 二进制里可以确认它在 Linux 下贴图的**确切实现**
（`/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`）：

```sh
# 第一步：探测剪贴板里有没有图
xclip -selection clipboard -t TARGETS -o 2>/dev/null \
  | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)" \
  || wl-paste -l 2>/dev/null | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"

# 第二步：把图捞出来
xclip -selection clipboard -t image/png -o > <临时文件> 2>/dev/null \
  || wl-paste --type image/png > <临时文件> 2>/dev/null \
  || xclip -selection clipboard -t image/bmp -o > <临时文件> 2>/dev/null \
  || wl-paste --type image/bmp > <临时文件>
```

它是**直接 `sh -c` 跑这两条命令**的，中间没有任何 `DISPLAY` 检查
（`DISPLAY` 只在"往剪贴板写"那条路径上才判断）。

> **结论：只要 PATH 里有个东西叫 `xclip`，能对上面两条命令给出正确输出，Ctrl+V 就能贴图。
> 它不必是真的 xclip，也不需要 X server。**

数据通路则由已有的挂载提供，不需要新开任何网络端口。

---

## 3. 架构

```
  macOS 宿主机                        桥接目录                        沙箱
 ┌────────────────────┐        ┌──────────────────────┐      ┌──────────────────┐
 │ clipbridge         │        │ ~/.clipboard-bridge/ │      │ xclip (垫片)      │
 │  .applescript      │  写入  │   clipboard.png      │ 读取 │  -t TARGETS -o   │
 │                    │ ─────► │   targets  ← 有图标志 │ ◄─── │  -t image/png -o │
 │ launchd 常驻       │        │   alive    ← 心跳     │      │        ▲         │
 │ 每 0.5s 查一次     │        └──────────────────────┘      │        │         │
 └────────────────────┘                                      │  Claude Code     │
                                                             │  按下 Ctrl+V     │
                                                             └──────────────────┘
```

**桥接目录在两种模式下的可见方式不同**，由 `ai-box` 启动时注入 `CLIP_BRIDGE_DIR`：

| 模式 | 宿主 Home 挂载 | 桥接目录在沙箱内的路径 |
|---|---|---|
| `aibox dev` | `--home-mount rw`，整个 Home，同路径 | `/Users/<user>/.clipboard-bridge` |
| `aibox` | 只挂项目目录 | `/run/aibox/clipboard-bridge`（ai-box 额外只读挂载） |
| `aibox ~`（项目就是 Home） | 项目挂载已包含桥接目录 | `/workspace/<项目名>/.clipboard-bridge` |

最后一行是特例：此时再单独挂一次等于同一宿主机路径被共享两次，会触发 apple/container
的静默空挂载问题（见主 README「已知问题」），因此直接复用项目挂载里的那一份。

垫片在 `CLIP_BRIDGE_DIR` 缺失时会自行兜底（先找 `/run/aibox/clipboard-bridge`，
再找 `/Users/*/.clipboard-bridge`），所以绕过 `ai-box` 直接 `container machine run`
进来的会话同样能用。

**写入顺序**保证不会读到半张图：先删 `targets` → 写 `clipboard.png.tmp` → `mv` 就位 →
最后才写 `targets`。垫片只在 `targets` 存在时才宣告"有图"。

**心跳** `alive` 约每 5 秒更新一次。宿主机监听要是挂了，垫片发现心跳超过 30 秒就
拒绝再吐图 —— 避免一直粘出同一张陈年旧图。

---

## 4. 文件清单

```
clipboard-bridge/
├── README.md                     本文档
├── clipbridge.js                 macOS 常驻监听（JXA，默认）
├── clipbridge.applescript        同上的 AppleScript 版，保留作退路
├── diagnose.sh                   `aibox clip doctor` 的实现：前台自检
├── com.local.clipbridge.plist    launchd 模板（安装时替换占位符）
├── install-host.sh               宿主机侧安装器（由 aibox clip 调用）
├── xclip-shim.sh                 垫片 → 镜像内 /usr/local/bin/xclip
└── img.sh                        兜底工具 → 镜像内 /usr/local/bin/aibox-img
```

后两个由 `Dockerfile` COPY 进镜像，`aibox build`（以及基于它的 `aibox dev build`）
之后开箱即用。前三个是 macOS 侧的东西，装不进任何镜像。

---

## 5. 安装

### 沙箱侧

无需操作 —— 已在镜像里。若镜像是加入本功能之前构建的，重建一次：

```bash
aibox build
aibox dev build     # 需要持久开发机时
```

### 宿主机侧（在 macOS 上执行一次）

```bash
aibox clip install
```

装成 launchd 用户级常驻服务 `com.local.clipbridge`，开机自启。

### 验证

在 macOS 上复制一张图（⌃⇧⌘4 截图到剪贴板，或网页里右键复制图片），然后：

```bash
aibox clip status
```

看到「有图可粘」就成了。回到沙箱里的 Claude Code 按 **Ctrl+V**。

`aibox status` 与 `aibox dev status` 也各有一行 `剪贴板贴图`，一屏自检时就能看到桥接
是否正常，不必单独记 `aibox clip status`：

```
  剪贴板贴图 : 已启用，当前剪贴板有图（沙箱里按 Ctrl+V 粘贴）
  剪贴板贴图 : 已启用，当前剪贴板无图
  剪贴板贴图 : 未启用（aibox clip install 开启后可在沙箱里 Ctrl+V 贴图）
  剪贴板贴图 : 异常：心跳 600 秒未更新，监听可能已停（试 aibox clip restart）
```

> ⚠️ 是 **Ctrl+V**，不是 ⌘V。⌘V 会被 macOS 终端自己截走当成文本粘贴，
> 根本不会传进沙箱；只有 `^V` 才会作为字节送进去交给 Claude Code。

---

## 5.1 关于延迟与重复粘贴

### 截图后要等 1~2 秒才能粘贴

早期版本用 AppleScript 的 `clipboard info` 检测剪贴板变化。它为了报告各数据类型的字节数，
**会真的把图解码一遍** —— 实测每轮循环约 1.2~1.5 秒（图越大越慢），`stderr` 里还会不停累积
ImageIO 的 `JP2 color space` 噪音，而且只要剪贴板里躺着一张图就一直在烧 CPU。

现在改用 JXA 读 `NSPasteboard.changeCount`：一个 O(1) 的整数，不触发任何渲染。轮询 0.2 秒、
去抖 0.12 秒，空闲时 CPU 约 0.1%。在 macOS 26.2 上实测（从剪贴板写入完成到 `targets` 出现）：

| 图片大小 | 落图耗时 |
|---|---|
| 12 KB | 0.36 s |
| 3.8 MB | 0.48 s |

`aibox clip doctor` 会把 `changeCount` 的成本直接量出来。

如果用的是**系统自带截图**（⌘⇧4 等），还要叠加一层与桥接无关的延迟：截完后右下角的浮动
缩略图会停留约 5 秒，在它消失之前这张图并没有真正写进剪贴板。⌘⇧5 →「选项」→ 取消勾选
「显示浮动缩略图」即可，或者截完后把缩略图向右轻扫。第三方截图工具通常没有这个行为。

### 心跳间隔比 5 秒长得多

同一个根因的另一种表现。心跳原本按「循环轮次」计数（每 10 轮一次），而一轮的实际耗时会
随剪贴板内容剧烈波动，于是名义 5 秒的心跳实测变成 12~20 秒 —— 距离垫片 30 秒的超时保护
已经很近，再慢一点就会误判成「监听已停」。现在两个实现都改成按**墙钟时间**计。

### 一次截图生成了多次 targets

有些截图/剪贴板工具分多步写入剪贴板（先清空、再写数据），每一步都会让 `changeCount` 自增。
不去抖就会一次截图触发多次捕获，而 `capture()` 每次都先删 `targets` 再重写 —— 表现就是
`targets` 反复生成；更糟的是中间那次往往对应「空剪贴板」，此刻按 Ctrl+V 会「没反应」。

监听在检测到变化后会等 `changeCount` 稳定（每 0.15 秒复查一次，最多 1.5 秒）再抓，
把多步写入收敛成一次捕获。代价是固定增加约 0.15 秒延迟。

日志里每次捕获都带 `changeCount=N`，可以直接数一次截图到底触发了几次。

### 同一张图被重复粘贴

垫片默认**一张图只交付一次**。剪贴板本身不会因为粘贴而清空（真 xclip 也是如此），
但在这里连按几次 Ctrl+V 就会叠出多张一模一样的附件 —— 尤其是在等待期间以为「没反应」
而反复按的时候。

交付后垫片会记下该图的「大小 + mtime」指纹，之后不再重复交付。重新复制一次即可再粘贴
（每次捕获都是原子重写，mtime 必变，所以即使是同一张图也算新的）。想恢复成可重复粘贴：

```bash
CLIP_BRIDGE_ONESHOT=0
```

消费标记存在容器本地的 `${TMPDIR:-/tmp}/clipboard-bridge/`，不写进桥接目录 ——
一次性容器里那是**只读**挂载。这也意味着标记按容器隔离，互不干扰。

## 6. 隐私与权限

监听**只镜像图片，绝不镜像剪贴板文本**。这是刻意设计的 —— 否则密码管理器里复制的
东西会被明文写到磁盘上。垫片对 `text/plain` 一律返回失败；文本粘贴走终端自带的就够了。

桥接目录权限是 `0755` 而不是 `0700`：一次性容器里的运行用户是 `node`（UID 1000），
与宿主机用户 UID 不同，`0700` 会导致挂进去的目录读不到。鉴于目录里只会出现你主动
复制的图片，这个放宽是可接受的。卸载时整个目录删除。

---

## 7. 卸载

```bash
aibox clip uninstall
```

沙箱侧的垫片留在镜像里不动 —— 桥接目录一消失，它就会安静地报告"没有图"，
不影响任何其他功能。

---

## 8. 排错

| 现象 | 排查 |
|---|---|
| Ctrl+V 没反应 | 先看 `aibox status` 的「剪贴板贴图」行，或 `aibox clip status` 看详情 |
| 提示没有心跳 | 监听没起来，看 `~/.clipboard-bridge/clipbridge.err` |
| 粘出来是旧图 | 心跳超时保护（30 秒）。说明监听挂了，`aibox clip restart` |
| 截图后要等几秒 | 多半是 macOS 的浮动缩略图，见上文「关于延迟」 |
| 想换回 AppleScript 版 | `CLIPBRIDGE_IMPL=applescript aibox clip install` |
| 改了监听脚本不生效 | 用 `aibox clip restart`（它会重新渲染 plist）；`aibox clip status` 第一行会打印当前实际加载的实现 |
| `Bootstrap failed: 5` | `launchctl bootout` 是异步的，紧接着 bootstrap 会撞进未卸载完的窗口。安装器现在会等旧 job 消失再加载并重试；若仍失败，先手动 `launchctl bootout gui/$(id -u)/com.local.clipbridge` 再重跑 |
| 沙箱里 `xclip` 不存在 | 镜像是加入本功能前构建的，重跑 `aibox build` |
| 已有的 `aibox-dev` 里没有 | 持久开发机的系统盘不随镜像更新，见下方「已存在的开发机」 |
| 一次性容器里不生效 | 桥接目录必须在**容器启动前**就存在。先 `aibox clip install`，再开新容器 |

### 已存在的开发机

`aibox dev build` 只是重建镜像；已经创建过的 `aibox-dev` 有自己的持久系统盘，不会因此
拿到垫片。要么重建机器（`aibox dev delete` 后再 `aibox dev`，会丢掉机内已安装的软件），
要么在机内直接软链过去（脚本本体在宿主 Home 上，机器重启后依然有效）：

```bash
sudo ln -snf ~/ai-sandbox/clipboard-bridge/xclip-shim.sh /usr/local/bin/xclip
sudo ln -snf ~/ai-sandbox/clipboard-bridge/img.sh        /usr/local/bin/aibox-img
```

### 兜底方案（不依赖桥接）

- `aibox-img` —— 打印宿主机最近的图片路径，直接把路径给 Claude Code
- `aibox dev` 下 ⌘⇧4 截图默认存到桌面，沙箱里就是 `/Users/<user>/Desktop/...`
- 从访达把文件拖进终端窗口，路径会自动填入
