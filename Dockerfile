# 基于官方 Node LTS,Claude Code 和 Codex CLI 都是 npm 包
FROM node:22-bookworm

# ============================================================================
# 层顺序原则:按「改动频率」从低到高排 —— 越少变的越靠前,越常变的越靠后。
# Docker 缓存规则:某层一旦变化,它「后面所有层」全部失效重跑。
# 这里最常变的是两个 AI CLI 的版本(`ai-box update` 每次都改 ARG 版本号),
# 所以把 npm 安装层放到最末尾(USER/ENTRYPOINT 等纯元数据层之前),
# `ai-box update` 只改靠后的版本 ARG,前面的 apt / locale / 可选本地包 / ipcheck 层可复用缓存。
# 修改 Dockerfile 或 third_party/ 内容时,则从对应层开始重新构建。
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
# 下面只识别三个约定文件,彼此独立、任意组合均可:
#   gost          容器内 HTTP -> 上游代理转换器;仅配置 AIBOX_PROXY 时需要
#   jdk8.tar.gz   JDK 8 发行包,解压后顶层目录会被剥离
#   maven.tar.gz  Maven 发行包,解压后顶层目录会被剥离
# 未提供这些文件时不会安装对应组件,Claude Code / Codex 核心镜像仍可正常构建。
COPY third_party/ /tmp/third_party/
RUN set -eux; \
    if [ -f /tmp/third_party/gost ]; then \
        install -m 0755 /tmp/third_party/gost /usr/local/bin/gost; \
        /usr/local/bin/gost -V; \
    fi; \
    if [ -f /tmp/third_party/jdk8.tar.gz ]; then \
        mkdir -p /opt/java/jdk8; \
        tar -xzf /tmp/third_party/jdk8.tar.gz -C /opt/java/jdk8 --strip-components=1; \
        test -x /opt/java/jdk8/bin/java; \
        /opt/java/jdk8/bin/java -version; \
    fi; \
    if [ -f /tmp/third_party/maven.tar.gz ]; then \
        mkdir -p /opt/maven; \
        tar -xzf /tmp/third_party/maven.tar.gz -C /opt/maven --strip-components=1; \
        test -x /opt/maven/bin/mvn; \
    fi; \
    if [ -x /opt/java/jdk8/bin/java ] && [ -x /opt/maven/bin/mvn ]; then \
        JAVA_HOME=/opt/java/jdk8 PATH="/opt/java/jdk8/bin:/opt/maven/bin:$PATH" /opt/maven/bin/mvn -v; \
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

# ---- 预建挂载点父目录,归属 node ----
# ai-box 会把宿主机 ~/.m2/repository 挂到 /home/node/.m2/repository。
# 若 /home/node/.m2 不存在,容器运行时会以 root 自动补建这个中间目录,
# 导致 entrypoint(node 用户)往里写 settings.xml 时 Permission denied、容器启动即退。
# 在镜像里先建好并 chown,运行时就只做挂载、不再补建。.gradle 同理顺手建上。
RUN mkdir -p /home/node/.m2 /home/node/.gradle \
    && chown node:node /home/node/.m2 /home/node/.gradle

# ---- 让 node 用户免密 sudo:entrypoint 要在运行期做两件 root-only 的事 ----
# 容器以 node(非 root)运行,但「设系统时区(/etc/localtime,ipcheck 看的是这个)」和
# 「关 IPv6(sysctl)」都需要 root。给 node 配 NOPASSWD sudo,entrypoint 用 `sudo -n` 完成。
# 因此 node 用户在容器内拥有免密 sudo;使用者应把容器及其可写挂载视为受信任执行环境。
RUN echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

# ---- 名称解析优先 IPv4 ----
# 作为「关 IPv6」的兜底:即便运行期 sysctl 关不掉,getaddrinfo 也优先返回 IPv4,
# 让工具走 IPv4。(entrypoint 里还会用 sudo sysctl 真正关掉 IPv6。)
RUN echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

# ============ 最重、最常变的层:两个 AI CLI(`ai-box update` 每次都改这里)============
# 放在所有「联网/耗时」层的最后,升级只重跑本层 —— 后面仅剩 entrypoint 的本地 COPY
# 和 USER/ENTRYPOINT 等零成本元数据层。
#   - Claude Code:  @anthropic-ai/claude-code
#   - Codex CLI:    @openai/codex
# 版本号由下面两个 ARG 锁定:宿主机跑 `ai-box update` 会查 npmmirror 最新版、
# 输出对比结果并在确认后改写这两行;版本号一变本层缓存失效(且因为在最后,不连累其它层)。
# npm 官方源在 builder 里可能同样解析不稳,改用淘宝镜像(通常不被污染)。
# 注意:npm install -g 写 /usr/local,须以 root 执行,故必须在下面 `USER node` 之前。
ARG CLAUDE_CODE_VERSION=2.1.207
ARG CODEX_VERSION=0.142.5
RUN npm config set registry https://registry.npmmirror.com \
    && npm install -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
    && npm config delete registry

# ---- 入口脚本:初始化运行环境,按需启动 gost,再执行目标命令 ----
# 特意放在 npm 层「之后」:entrypoint.sh 偶尔改动时不会连累重装两个 CLI;
# 反过来 CLI 升级触发的这层 re-COPY 只是本地文件拷贝,无网络开销,可忽略。
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 用非 root 用户运行,避免容器内生成的文件在宿主机上属于 root。
# 使用 node 基础镜像自带的非 root 用户;挂载目录权限仍取决于容器运行时的映射方式。
USER node

# 项目会挂载到这里
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
