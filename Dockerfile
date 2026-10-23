# 基于官方 Node LTS,Claude Code 和 Codex CLI 都是 npm 包
FROM node:22-bookworm

# ============================================================================
# 层顺序原则:按「改动频率」从低到高排 —— 越少变的越靠前,越常变的越靠后。
# Docker 缓存规则:某层一旦变化,它「后面所有层」全部失效重跑。
# 这里最常变的是两个 AI CLI 的版本,npm 安装层放到最末尾(USER/ENTRYPOINT 等
# 纯元数据层之前),前面的 apt / locale / 可选本地包 / ipcheck 层可复用缓存。
#
# 注意:日常升级 CLI 走的不是本文件全量构建 —— apple/container 的 builder 层缓存
# 不可靠(builder 删除重建后全丢),全量构建常常等于重下所有依赖。`aibox tmp update`
# 把确认后的版本记在 ~/.aibox/versions.env(本文件不改),实际构建用 Dockerfile.update
# 在现有镜像上增量叠一层 npm install。本文件用于首次构建、修改配方后的重建,
# 以及多次增量更新后的「压平」重建(aibox build)。
# ============================================================================

# ---- apt 基础工具(极少变)----
# 装一些日常开发常用工具:git、ripgrep(Claude Code 用它搜索)、常用编辑器等
# 另外装 Python3 + pip:ipcheck(ai-ipcheck)是 Python 包,需要 3.10+
# (bookworm 自带 Python 3.11,满足要求)。
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ripgrep \
        curl \
        ca-certificates \
        less \
        vim \
        sudo \
        iptables \
        util-linux \
        python3 \
        python3-pip \
        tzdata \
        locales \
    && rm -rf /var/lib/apt/lists/*

# ---- 时区 / 语言:构建期只准备「可用集合」,具体用哪个交给运行期 aibox.conf 决定 ----
# 背景:时区/语言原本烧死在镜像里(改一次要重建),现改为运行期可选 —— 见 entrypoint.sh
#      按 AIBOX_TZ / AIBOX_LANG 生效,没配则由 ai-box 传宿主机的值进来。
#      修改这些运行期设置只需更新 aibox.conf,无需重建镜像。
# 时区:tzdata 已装(含所有时区),运行期用 TZ 环境变量选择即可,无需构建期烧死。
# 语言:locale 必须构建期生成才能用,所以这里预生成一组常用的;运行期 AIBOX_LANG 从中任选。
#      要加别的语言:往 LOCALE_GEN 追加对应 <locale>.UTF-8 再 `aibox build`。
# 默认值设中性(UTC / C.UTF-8):运行期没配且宿主机也取不到时才用到。
ARG LOCALE_GEN="en_US.UTF-8 en_GB.UTF-8 zh_CN.UTF-8 zh_TW.UTF-8 ja_JP.UTF-8 ko_KR.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8 pt_BR.UTF-8 ru_RU.UTF-8 it_IT.UTF-8"
RUN for loc in ${LOCALE_GEN}; do \
        sed -i "s/^# *${loc} /${loc} /" /etc/locale.gen; \
    done \
    && locale-gen
ENV TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ============ 可选本地包(third_party/)层:构建期只 COPY 不联网,极少变 ============

# 整目录复制,因此公开仓库只保留 third_party/.gitkeep 时也能构建。
# 只识别一个约定文件:
#   gost          容器内 HTTP -> 上游代理转换器;仅配置 AIBOX_PROXY 时需要
# 未提供时不安装,Claude Code / Codex 核心镜像仍可正常构建。
COPY third_party/ /tmp/third_party/
RUN set -eux; \
    if [ -f /tmp/third_party/gost ]; then \
        install -m 0755 /tmp/third_party/gost /usr/local/bin/gost; \
        /usr/local/bin/gost -V; \
    fi; \
    rm -rf /tmp/third_party

# ---- ipcheck:网络环境诊断工具(检测 IP/DNS/代理/时区等信息)----
# 来自 https://github.com/stormzhang/ipcheck,PyPI 包名 ai-ipcheck,命令入口 ipcheck。
# 输出用于排查容器网络环境;结果不代表任何第三方服务的接入或账号判定。
# 说明:
#   --break-system-packages 绕过 Debian bookworm 的 PEP 668 保护(允许全局 pip 装)。
#   用官方 PyPI 源:ai-ipcheck 是新包,清华等镜像可能还没同步收录。
#   ★ 注意:这里不再用 `|| true` 兜底,pip 装失败会让构建直接报错(避免静默漏装)。
#   最后一行验证 ipcheck 确实可执行,不可执行则构建失败。
# ★ 放在 npm 层之前:升级 CLI 版本时不会连累这层重新去 PyPI 下载 ai-ipcheck。
RUN pip3 install --break-system-packages ai-ipcheck \
    && command -v ipcheck

# ---- 让 Claude Code 的全局配置落进挂载目录,实现登录/信任/引导状态持久化 ----
# 背景:ai-box 只挂载 ~/.claude 目录。而 Claude Code 的全局配置文件 .claude.json
#      默认在 $HOME/.claude.json,是 .claude 目录的「同级兄弟」,落在挂载点之外,
#      随 --rm 容器销毁 → 每次进容器都丢 hasCompletedOnboarding / oauthAccount /
#      目录信任(hasTrustDialogAccepted),表现为「授权没继承、反复要求信任目录」。
# 解法:Claude Code 支持 CLAUDE_CONFIG_DIR,设了之后 .claude.json 会落在
#      $CLAUDE_CONFIG_DIR/.claude.json(而非 $HOME/.claude.json)。把它指向已挂载的
#      /home/node/.claude,.claude.json 就进了挂载卷,跨容器持久化。
#      credentials/settings/projects/sessions 本来就在这个目录里,此改动只挪 .claude.json,
#      不影响登录、无需重登。且是让 Claude 在「目录挂载」上正常建文件,不是当年
#      单文件 bind-mount 空 .claude.json 的坑,不会复现 Unexpected EOF。
# 注:codex 无此问题——它整个配置根 $CODEX_HOME 默认就是 ~/.codex(auth/config 全在里面),
#      而 ~/.codex 已被整目录挂载,无游离在挂载点外的配置文件。
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# ---- 运行期目录:ai-box 把临时 env-file 等挂到 /run/aibox 下 ----
RUN mkdir -p /run/aibox \
    && chmod 0711 /run/aibox

# gost 使用独立 UID 建立唯一允许直连外网的连接。普通 node 进程只能访问
# loopback 上的本地 HTTP 代理,忽略代理环境变量也无法绕过防火墙。
RUN useradd --system --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin aibox-gost

# ---- 直连模式保留 sudo;代理模式会在 entrypoint 初始化后撤销 ----
# entrypoint 以 root 启动,完成系统时区、IPv6 和可选防火墙设置后降权到 node。
# 直连模式保留原有开发体验;代理模式删除此 sudoers 文件并启用 no_new_privs,
# 防止容器进程提权清空强制代理防火墙。
RUN echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

# ---- 名称解析优先 IPv4 ----
# 作为「关 IPv6」的兜底:即便运行期 sysctl 关不掉,getaddrinfo 也优先返回 IPv4,
# 让工具走 IPv4。(entrypoint 的 root 初始化阶段还会尝试真正关掉 IPv6。)
RUN echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

# ============ 最重、最常变的层:两个 AI CLI ============
# 放在所有「联网/耗时」层的最后,全量重建时若缓存可用,版本变化只重跑本层 ——
# 后面仅剩 entrypoint 的本地 COPY 和 USER/ENTRYPOINT 等零成本元数据层。
#   - Claude Code:  @anthropic-ai/claude-code
#   - Codex CLI:    @openai/codex
# 下面两个 ARG 是随 aibox 发布的默认版本。宿主机跑 `aibox tmp update` 确认升级后,
# 版本记在 ~/.aibox/versions.env;全量构建时 ai-box 取两者中较新的,用 --build-arg 传入,
# 所以之后任何一次全量重建都复现相同版本。
# npm 官方源在 builder 里可能同样解析不稳,改用淘宝镜像(通常不被污染)。
# 注意:npm install -g 写 /usr/local,须以 root 执行。
ARG CLAUDE_CODE_VERSION=2.1.233
ARG CODEX_VERSION=0.147.0
RUN npm config set registry https://registry.npmmirror.com \
    && npm install -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
    && npm config delete registry

# ---- 入口脚本:初始化运行环境,按需启动 gost,再执行目标命令 ----
# 特意放在 npm 层「之后」:entrypoint.sh 偶尔改动时不会连累重装两个 CLI;
# 反过来 CLI 升级触发的这层 re-COPY 只是本地文件拷贝,无网络开销,可忽略。
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY network-lockdown.sh /usr/local/sbin/aibox-network-lockdown
COPY user-exec.sh /usr/local/bin/aibox-user-exec
COPY enter-shell.sh /usr/local/sbin/aibox-enter-shell

# ---- 剪贴板图片桥接:冒充 xclip,让沙箱里的 Claude Code 支持 Ctrl+V 贴图 ----
# 终端只能把「文本」当键盘输入送进 tty,图片传不过来;要贴图必须由程序自己读操作系统
# 剪贴板,而沙箱里既没有 X11/Wayland 也够不到 macOS 剪贴板。Claude Code 在 Linux 下
# 贴图恰好是 sh -c 调 `xclip -t TARGETS/-t image/png`,且不检查 DISPLAY,于是这里放一个
# 同名垫片,数据源换成宿主机侧常驻监听写出的 PNG。宿主机那一半装不进镜像,
# 由 `aibox clip install` 在 macOS 上安装。详见 clipboard-bridge/README.md。
COPY clipboard-bridge/xclip-shim.sh /usr/local/bin/xclip
COPY clipboard-bridge/img.sh /usr/local/bin/aibox-img

RUN chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/aibox-user-exec \
        /usr/local/sbin/aibox-network-lockdown \
        /usr/local/sbin/aibox-enter-shell \
        /usr/local/bin/xclip \
        /usr/local/bin/aibox-img

# entrypoint 需要 root 初始化网络,执行用户命令前会不可逆地降权到 node。
USER root

# 项目会挂载到这里
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
