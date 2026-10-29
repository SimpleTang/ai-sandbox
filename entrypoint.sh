#!/usr/bin/env bash
# 容器入口:以 root 初始化网络/系统设置,不可逆降权到 node 后再启动用户命令。
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
# 代理链路:所有普通进程只能连接 loopback 上的本地 HTTP 端点;防火墙只允许
# 专用 aibox-gost UID 连接外网。忽略代理变量或使用原始 socket 也会被拒绝。
set -euo pipefail

LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-8080}"
export LOCAL_HTTP_PORT

# ---- root 初始化阶段 ----
# 镜像以 root 启动入口脚本。代理模式需要 CAP_NET_ADMIN;规则生效并启动 gost 后,
# 删除 node 的 sudoers 规则,再清空 capability bounding set + no_new_privs 降权。
if [[ "${AIBOX_ENTRYPOINT_PHASE:-}" != "user" ]]; then
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "错误: 当前镜像仍以非 root 用户启动,无法安装强制代理防火墙。" >&2
        echo "      本次升级修改了镜像权限模型,请先运行 aibox build 全量重建。" >&2
        exit 1
    fi

    # 自定义用户变量绝不进入 root 入口环境;只把挂载内容复制给稍后的 node 阶段。
    if [[ -f /run/aibox/user-env ]]; then
        install -o node -g node -m 0600 \
            /run/aibox/user-env /run/aibox/user-env-runtime
    fi

    # IPv6 即使无法通过 sysctl 关闭,代理模式的 ip6tables 仍会阻断直连。
    for _k in all default lo; do
        # 重定向按从左到右生效:写成 `> 文件 2>/dev/null` 时,打开文件失败的报错发生在
        # 2>/dev/null 之前,/proc/sys 只读时仍会刷出 "Read-only file system"。用 { } 包起来再丢弃。
        { printf '1\n' > "/proc/sys/net/ipv6/conf/${_k}/disable_ipv6"; } 2>/dev/null || true
    done
    if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        AIBOX_IPV6_SHOWN="已关闭(无 IPv6 栈)"
    elif [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
        AIBOX_IPV6_SHOWN="已关闭"
    else
        AIBOX_IPV6_SHOWN="未关闭"
    fi

    # 系统时区必须在降权前设置;用户阶段再导出 TZ 并写入 .bashrc。
    AIBOX_TZ_SHOWN="镜像默认(${TZ:-UTC})"
    if [[ -n "${AIBOX_TZ:-}" ]]; then
        export TZ="$AIBOX_TZ"
        sys_tz="仅CLI"
        if [[ -e "/usr/share/zoneinfo/$AIBOX_TZ" ]]; then
            ln -snf "/usr/share/zoneinfo/$AIBOX_TZ" /etc/localtime
            printf '%s\n' "$AIBOX_TZ" > /etc/timezone
            [[ "$(readlink /etc/localtime 2>/dev/null)" == *"/$AIBOX_TZ" ]] && sys_tz="系统+CLI"
        fi
        AIBOX_TZ_SHOWN="$AIBOX_TZ  [${AIBOX_TZ_SRC:-?}, $sys_tz]"
    fi

    AIBOX_NETWORK_SHOWN="直连(未启用出口防火墙)"
    drop_privilege_args=()
    if [[ -n "${AIBOX_PROXY:-}" ]]; then
        if ! command -v gost >/dev/null 2>&1; then
            echo "错误: 已配置 AIBOX_PROXY,但镜像中未安装 gost。" >&2
            echo "      请将当前架构的 gost 二进制放到 third_party/gost,重新运行 aibox build。" >&2
            exit 1
        fi
        if ! command -v setpriv >/dev/null 2>&1 || [[ ! -x /usr/local/sbin/aibox-network-lockdown ]]; then
            echo "错误: 镜像缺少强制代理组件,请运行 aibox build 全量重建。" >&2
            exit 1
        fi

        gost_uid="$(id -u aibox-gost)"
        gost_gid="$(id -g aibox-gost)"
        /usr/local/sbin/aibox-network-lockdown "$gost_uid"
        # Mac 应用控制(aibox cu):只放行到宿主机网关的这一个 IPv4 地址和端口,插在拒绝规则之前。
        # 网关自己要求 token,且只有容器网络能连到它。
        if [[ "${AIBOX_CU_ENDPOINT:-}" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
            iptables -w -I AIBOX_OUTPUT 1 -d "${BASH_REMATCH[1]}" -p tcp --dport "${BASH_REMATCH[2]}" -j ACCEPT
        fi

        # gost 是唯一可访问外网的 UID;日志不回显,避免上游 URL 或账密泄漏。
        case "$AIBOX_PROXY" in
            *\?*) gost_query_sep="&" ;;
            *)    gost_query_sep="?" ;;
        esac
        setpriv --reuid="$gost_uid" --regid="$gost_gid" --clear-groups \
            --bounding-set=-all --no-new-privs -- \
            gost -L "http://127.0.0.1:${LOCAL_HTTP_PORT}" \
                 -F "${AIBOX_PROXY}${gost_query_sep}retry=3&timeout=8s&so_keepalive=true" \
                 >/tmp/gost.log 2>&1 &
        gost_pid=$!
        sleep 1
        if ! kill -0 "$gost_pid" 2>/dev/null; then
            echo "错误: gost 启动失败;为避免直连泄漏,容器拒绝继续启动。" >&2
            exit 1
        fi

        # 普通进程既没有外网规则,也不能再通过 sudo/capability 修改防火墙。
        rm -f /etc/sudoers.d/node
        : > /run/aibox/proxy-lockdown
        chmod 0400 /run/aibox/proxy-lockdown
        drop_privilege_args=(--bounding-set=-all --no-new-privs)
        AIBOX_NETWORK_SHOWN="强制代理(fail-closed, IPv4+IPv6)"
    fi

    export AIBOX_ENTRYPOINT_PHASE="user"
    export AIBOX_IPV6_SHOWN AIBOX_TZ_SHOWN AIBOX_NETWORK_SHOWN
    node_uid="$(id -u node)"
    node_gid="$(id -g node)"
    exec setpriv --reuid="$node_uid" --regid="$node_gid" --init-groups \
        "${drop_privilege_args[@]}" -- \
        env HOME=/home/node USER=node LOGNAME=node \
        /usr/local/bin/entrypoint.sh "$@"
fi

if [[ "$(id -u)" -eq 0 ]]; then
    echo "错误: aibox 入口脚本未能降权到 node。" >&2
    exit 1
fi

BASHRC="$HOME/.bashrc"

# ---- 时区 ----
# root 阶段已设置系统时区;这里持久化 shell 环境供 aibox enter 复用。
TZ_SHOWN="${AIBOX_TZ_SHOWN:-镜像默认(${TZ:-UTC})}"
if [[ -n "${AIBOX_TZ:-}" ]]; then
    export TZ="$AIBOX_TZ"
    echo "export TZ=$AIBOX_TZ" >> "$BASHRC"     # 让 aibox enter 的交互 shell 也一致
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
    # 脱敏:socks5://user:pass@host -> socks5://***@host(用户名和密码都不显示)
    masked="$(printf '%s' "$AIBOX_PROXY" | sed -E 's#(://)[^/@]*@#\1***@#')"

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

    PROXY_SHOWN="${masked}  [${AIBOX_PROXY_SRC:-?}]"
else
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
echo "      网络 : ${AIBOX_NETWORK_SHOWN:-未知}"
echo "      时区 : ${TZ_SHOWN}"
echo "      语言 : ${LANG_SHOWN}"
echo "      IPv6 : ${AIBOX_IPV6_SHOWN:-未知}"
echo "==> ──────────────────────────────────"

exec /usr/local/bin/aibox-user-exec "$@"
