#!/usr/bin/env bash
# 容器入口:按 ai-box 传入的关键参数生效「代理 / 时区 / 语言」,打印启动横幅,再起 shell。
#
# 由 ai-box(宿主机)通过 -e 传入(都可为空):
#   AIBOX_PROXY   上游代理 URL(http/https/socks5/socks5h... gost 认的都行);空 = 直连
#   AIBOX_TZ      时区,如 Asia/Shanghai;空 = 用镜像默认(UTC)
#   AIBOX_LANG    语言 locale,如 en_US.UTF-8;空 = 用镜像默认(C.UTF-8)
#   AIBOX_PROJECT 项目名(提示符显示)
#
# 可选:
#   LOCAL_HTTP_PORT  容器内本地 HTTP 代理端口(默认 8080)
#
# 代理链路:遵循代理环境变量的程序连接本地 HTTP 端点,gost 再转发到 AIBOX_PROXY。
# Maven/Gradle 另写代理配置;原始 socket 或忽略代理配置的程序不保证经过该链路。
set -euo pipefail

LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-8080}"
BASHRC="$HOME/.bashrc"
MAVEN_SETTINGS="$HOME/.m2/settings.xml"
GRADLE_PROPERTIES="$HOME/.gradle/gradle.properties"
MAVEN_PROXY_MARKER="<!-- Managed by ai-box: proxy settings -->"
GRADLE_PROXY_BEGIN="# >>> ai-box managed proxy >>>"
GRADLE_PROXY_END="# <<< ai-box managed proxy <<<"

# 去掉 ai-box 自己写入的 Gradle 代理块,保留用户的其他 gradle.properties 配置。
# 旧版本生成的是一个不带标记、只含五个代理属性的文件,也一并识别并清理。
remove_aibox_gradle_proxy() {
    local file="$GRADLE_PROPERTIES" tmp nonempty_lines
    [[ -f "$file" ]] || return 0

    if grep -qxF "$GRADLE_PROXY_BEGIN" "$file"; then
        grep -qxF "$GRADLE_PROXY_END" "$file" || return 1
        [[ -w "$file" ]] || return 1
        tmp="$(mktemp "${file}.aibox.XXXXXX")" || return 1
        if ! awk -v begin="$GRADLE_PROXY_BEGIN" -v end="$GRADLE_PROXY_END" '
            $0 == begin { managed = 1; next }
            $0 == end   { managed = 0; next }
            !managed    { print }
        ' "$file" > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        if grep -q '[^[:space:]]' "$tmp"; then
            mv "$tmp" "$file"
        else
            rm -f "$tmp" "$file"
        fi
        return 0
    fi

    nonempty_lines="$(sed '/^[[:space:]]*$/d' "$file" | wc -l | tr -d '[:space:]')"
    if [[ "$nonempty_lines" == "5" ]] \
       && grep -qxF 'systemProp.http.proxyHost=127.0.0.1' "$file" \
       && grep -qE '^systemProp.http.proxyPort=[0-9]+$' "$file" \
       && grep -qxF 'systemProp.https.proxyHost=127.0.0.1' "$file" \
       && grep -qE '^systemProp.https.proxyPort=[0-9]+$' "$file" \
       && grep -qxF 'systemProp.http.nonProxyHosts=localhost|127.0.0.1' "$file"; then
        rm -f "$file"
    fi
}

remove_aibox_maven_proxy() {
    [[ -f "$MAVEN_SETTINGS" ]] || return 0
    if grep -qF "$MAVEN_PROXY_MARKER" "$MAVEN_SETTINGS"; then
        [[ -w "$MAVEN_SETTINGS" ]] || return 1
        rm -f "$MAVEN_SETTINGS"
    fi
}

# ---- 可选 Java / Maven 工具链 ----
# Dockerfile 只安装 third_party/ 中实际提供的组件。这里按安装结果设置环境,
# 同时写入 .bashrc,让 `aibox enter` 打开的新交互 shell 继承相同配置。
TOOLCHAIN_BIN_PATH=""
if [[ -x /opt/java/jdk8/bin/java ]]; then
    export JAVA_HOME=/opt/java/jdk8
    TOOLCHAIN_BIN_PATH="$JAVA_HOME/bin"
    echo 'export JAVA_HOME=/opt/java/jdk8' >> "$BASHRC"
fi
if [[ -x /opt/maven/bin/mvn ]]; then
    export MAVEN_HOME=/opt/maven
    if [[ -n "$TOOLCHAIN_BIN_PATH" ]]; then
        TOOLCHAIN_BIN_PATH="$TOOLCHAIN_BIN_PATH:$MAVEN_HOME/bin"
    else
        TOOLCHAIN_BIN_PATH="$MAVEN_HOME/bin"
    fi
    echo 'export MAVEN_HOME=/opt/maven' >> "$BASHRC"
fi
if [[ -n "$TOOLCHAIN_BIN_PATH" ]]; then
    export PATH="$TOOLCHAIN_BIN_PATH:$PATH"
    printf 'export PATH="%s:$PATH"\n' "$TOOLCHAIN_BIN_PATH" >> "$BASHRC"
fi

# ---- 关闭 IPv6 ----
# 需要 root,用 node 的免密 sudo(sudo -n 不会挂起)。直接写 /proc/sys(等价 sysctl -w,
# 但不依赖 procps 是否装了 sysctl)。关不掉则靠 /etc/gai.conf 优先 IPv4 兜底。
for _k in all default lo; do
    echo 1 | sudo -n tee "/proc/sys/net/ipv6/conf/${_k}/disable_ipv6" >/dev/null 2>&1 || true
done
if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    IPV6_SHOWN="已关闭(无 IPv6 栈)"
elif [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
    IPV6_SHOWN="已关闭"
else
    IPV6_SHOWN="未关闭,仅优先 IPv4(内核拒绝?)"
fi

# ---- 时区 ----
# 同时设「系统时区」(/etc/localtime + /etc/timezone,ipcheck 判定的是这个)和
# 「CLI 时区」(TZ 环境变量)。前者需 root,用 sudo。
TZ_SHOWN="镜像默认(${TZ:-UTC})"
if [[ -n "${AIBOX_TZ:-}" ]]; then
    export TZ="$AIBOX_TZ"
    echo "export TZ=$AIBOX_TZ" >> "$BASHRC"     # 让 aibox enter 的交互 shell 也一致
    sys_tz="仅CLI"
    if [[ -e "/usr/share/zoneinfo/$AIBOX_TZ" ]]; then
        sudo -n ln -snf "/usr/share/zoneinfo/$AIBOX_TZ" /etc/localtime 2>/dev/null || true
        printf '%s\n' "$AIBOX_TZ" | sudo -n tee /etc/timezone >/dev/null 2>&1 || true
        [[ "$(readlink /etc/localtime 2>/dev/null)" == *"/$AIBOX_TZ" ]] && sys_tz="系统+CLI"
    fi
    TZ_SHOWN="$AIBOX_TZ  [${AIBOX_TZ_SRC:-?}, $sys_tz]"
fi

# ---- 语言 ----
# locale 必须镜像里已生成(见 Dockerfile LOCALE_GEN)才能用。locale -a 里的名字形如
# en_US.utf8,与 en_US.UTF-8 差在大小写与 UTF-8/utf8,做归一化后比对。
LANG_SHOWN="镜像默认(${LANG:-C.UTF-8})"
if [[ -n "${AIBOX_LANG:-}" ]]; then
    want_norm="$(printf '%s' "$AIBOX_LANG" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"
    if locale -a 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/' | grep -qx "$want_norm"; then
        export LANG="$AIBOX_LANG" LANGUAGE="${AIBOX_LANG%%.*}" LC_ALL="$AIBOX_LANG"
        {
            echo "export LANG=$AIBOX_LANG"
            echo "export LANGUAGE=${AIBOX_LANG%%.*}"
            echo "export LC_ALL=$AIBOX_LANG"
        } >> "$BASHRC"
        LANG_SHOWN="$AIBOX_LANG  [${AIBOX_LANG_SRC:-?}]"
    else
        echo "==> ⚠️  locale '$AIBOX_LANG' 镜像里没生成,回退 C.UTF-8。"
        echo "        (要用它:把它加进 Dockerfile 的 LOCALE_GEN 再 aibox build)"
        export LANG=C.UTF-8 LC_ALL=C.UTF-8
        LANG_SHOWN="C.UTF-8(回退,'$AIBOX_LANG' 未生成)"
    fi
fi

# ---- 代理 ----
if [[ -n "${AIBOX_PROXY:-}" ]]; then
    if ! command -v gost >/dev/null 2>&1; then
        echo "错误: 已配置 AIBOX_PROXY,但镜像中未安装 gost。" >&2
        echo "      请将当前架构的 gost 二进制放到 third_party/gost,重新运行 aibox build。" >&2
        exit 1
    fi

    # 脱敏:socks5://user:pass@host -> socks5://***@host(用户名和密码都不显示)
    masked="$(printf '%s' "$AIBOX_PROXY" | sed -E 's#(://)[^/@]*@#\1***@#')"

    # -L 本地监听 HTTP;-F 转发到上游(URL 决定协议)
    #   retry=3      遇到瞬时连接失败时最多重试 3 次
    #   timeout=8s   单次连接超时,超时即触发下一次重试
    #   so_keepalive 保活,减少长连接被中断
    gost -L "http://127.0.0.1:${LOCAL_HTTP_PORT}" \
         -F "${AIBOX_PROXY}?retry=3&timeout=8s&so_keepalive=true" \
         >/tmp/gost.log 2>&1 &
    sleep 1     # 等 gost 起来

    # 为遵循标准代理环境变量的程序设置本地 HTTP 代理
    export HTTP_PROXY="http://127.0.0.1:${LOCAL_HTTP_PORT}"
    export HTTPS_PROXY="$HTTP_PROXY"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTP_PROXY"
    export ALL_PROXY="$HTTP_PROXY"
    export all_proxy="$HTTP_PROXY"
    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="$NO_PROXY"

    # 写进 bashrc,交互式子 shell(含 aibox enter)里也生效
    {
        echo "export HTTP_PROXY=$HTTP_PROXY"
        echo "export HTTPS_PROXY=$HTTP_PROXY"
        echo "export http_proxy=$HTTP_PROXY"
        echo "export https_proxy=$HTTP_PROXY"
        echo "export ALL_PROXY=$HTTP_PROXY"
        echo "export all_proxy=$HTTP_PROXY"
        echo "export NO_PROXY=$NO_PROXY"
        echo "export no_proxy=$NO_PROXY"
    } >> "$BASHRC"

    # ---- JVM 系工具(Maven/Gradle)不认 HTTP_PROXY 环境变量,单独生成代理配置 ----
    # 任何一步失败都不该让容器起不来(set -e 下先检查目录可写)。
    mkdir -p "$HOME/.m2" 2>/dev/null || true
    if [[ ! -w "$HOME/.m2" ]]; then
        echo "==> ⚠️  $HOME/.m2 不可写(属主异常?),跳过 Maven 代理配置 —— mvn 将拉不到依赖!"
    elif [[ ! -f "$MAVEN_SETTINGS" ]] || grep -qF "$MAVEN_PROXY_MARKER" "$MAVEN_SETTINGS"; then
        cat > "$MAVEN_SETTINGS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
$MAVEN_PROXY_MARKER
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <proxies>
    <proxy>
      <id>gost-http</id><active>true</active><protocol>http</protocol>
      <host>127.0.0.1</host><port>${LOCAL_HTTP_PORT}</port>
      <nonProxyHosts>localhost|127.0.0.1</nonProxyHosts>
    </proxy>
    <proxy>
      <id>gost-https</id><active>true</active><protocol>https</protocol>
      <host>127.0.0.1</host><port>${LOCAL_HTTP_PORT}</port>
      <nonProxyHosts>localhost|127.0.0.1</nonProxyHosts>
    </proxy>
  </proxies>
</settings>
EOF
    fi
    mkdir -p "$HOME/.gradle" 2>/dev/null || true
    if [[ ! -w "$HOME/.gradle" ]]; then
        echo "==> ⚠️  $HOME/.gradle 不可写(属主异常?),跳过 Gradle 代理配置 —— gradle 将拉不到依赖!"
    elif ! remove_aibox_gradle_proxy; then
        echo "==> ⚠️  无法更新 $GRADLE_PROPERTIES,跳过 Gradle 代理配置。"
    elif [[ -f "$GRADLE_PROPERTIES" && ! -w "$GRADLE_PROPERTIES" ]]; then
        echo "==> ⚠️  $GRADLE_PROPERTIES 不可写,跳过 Gradle 代理配置。"
    else
        [[ -s "$GRADLE_PROPERTIES" ]] && printf '\n' >> "$GRADLE_PROPERTIES"
        cat >> "$GRADLE_PROPERTIES" <<EOF
$GRADLE_PROXY_BEGIN
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=${LOCAL_HTTP_PORT}
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=${LOCAL_HTTP_PORT}
systemProp.http.nonProxyHosts=localhost|127.0.0.1
$GRADLE_PROXY_END
EOF
    fi
    PROXY_SHOWN="${masked}  [${AIBOX_PROXY_SRC:-?}]"
else
    remove_aibox_maven_proxy \
        || echo "==> ⚠️  无法清理 $MAVEN_SETTINGS 中旧的 ai-box 代理配置。"
    remove_aibox_gradle_proxy \
        || echo "==> ⚠️  无法清理 $GRADLE_PROPERTIES 中旧的 ai-box 代理配置。"
    PROXY_SHOWN="直连(未配置代理)"
fi

# ---- 提示符:显示项目名,一眼分清哪个窗口是哪个项目 ----
if [[ -n "${AIBOX_PROJECT:-}" ]]; then
    echo 'export PS1="\[\e[32m\][${AIBOX_PROJECT}]\[\e[0m\] \w\$ "' >> "$BASHRC"
fi

# ---- 启动横幅:关键参数一屏核对,防止搞错 ----
echo "==> ───────── aibox 启动参数 ─────────"
echo "      目录 : ${AIBOX_HOST_DIR:-?}"
echo "      挂载 : ${AIBOX_MOUNT:-?}"
echo "      名称 : ${AIBOX_CONTAINER:-?}"
echo "      代理 : ${PROXY_SHOWN}"
echo "      时区 : ${TZ_SHOWN}"
echo "      语言 : ${LANG_SHOWN}"
echo "      IPv6 : ${IPV6_SHOWN}"
echo "==> ──────────────────────────────────"

exec "$@"
