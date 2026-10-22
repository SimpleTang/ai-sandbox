#!/usr/bin/env bash
# setup.sh —— aibox 安装向导:一步步检查并完成首次安装与配置
#
# 用法:
#   ./setup.sh             刚克隆仓库、还没有 aibox 命令时,在仓库目录里运行
#   aibox setup            安装后随时重跑:检查各步骤状态,按需调整配置
#   aibox setup --check    只检查不修改;有必需步骤未完成时退出码为 1
#
# 每一步先检测现状,已完成的直接跳过,所以可以反复运行;中途 Ctrl+C 退出,重跑即可续上。
# 向导做的事与 README「安装」「快速开始」里的手动步骤一致,不引入额外的运行期状态。
# 写法兼容 macOS 自带 Bash 3.2(无关联数组、无 mapfile、无 ${var,,})。
# 注意:变量后紧跟中文时必须写成 ${var},Bash 3.2 会把多字节字符当成变量名的一部分。
set -euo pipefail

SANDBOX_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
AIBOX="$SANDBOX_DIR/ai-box"
# 用户数据统一在 ~/.aibox(见 ai-box 开头的说明);程序目录只读
STATE_DIR="$HOME/.aibox"
CONF="$STATE_DIR/aibox.conf"
CONF_EXAMPLE="$SANDBOX_DIR/aibox.conf.example"
COMPLETION="$SANDBOX_DIR/ai-box-completion.sh"
GOST_PATH="$STATE_DIR/third_party/gost"
# 旧版放在程序目录里的位置;运行 aibox 时会自动搬到 ~/.aibox,--check 只读取并提示
LEGACY_CONF="$SANDBOX_DIR/aibox.conf"
LEGACY_GOST="$SANDBOX_DIR/third_party/gost"
LEGACY_NOTE=""
# 镜像名与 ai-box 保持一致
IMAGE="ai-sandbox:latest"
DEV_IMAGE="ai-sandbox-dev:latest"
BIN_DIR="$HOME/.local/bin"
LINK_PATH="$BIN_DIR/aibox"
CLIP_LABEL="com.local.clipbridge"
DEV_MACHINE_NAME="aibox-dev"
MIGRATED_MARK="$HOME/.aibox/.migrated"
TOTAL_STEPS=8

# gost:与 README 记录的已验证资产一致,校验的是解包后的二进制
GOST_VERSION="3.2.6"
GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_arm64.tar.gz"
GOST_SHA256="343c3e003996ca0437b9cc47dd1500cd0475ba09f5a5f17e50851854e06a1ca7"

# Apple container:下载已验证版本的官方签名安装包,打开前核对签名团队
# (Developer ID Installer: Apple Inc. - Containerization)。版本常量与 ai-box 保持一致。
CONTAINER_MIN_VERSION="1.0.0"
CONTAINER_TESTED_VERSION="1.6.0"
CONTAINER_RELEASES_URL="https://github.com/apple/container/releases"
CONTAINER_PKG_URL="https://github.com/apple/container/releases/download/${CONTAINER_TESTED_VERSION}/container-${CONTAINER_TESTED_VERSION}-installer-signed.pkg"
CONTAINER_PKG_TEAM="UPBK2H6LZM"
# 容器默认网络里宿主机的地址;查询失败时用这个已知默认值
DEFAULT_GATEWAY="192.168.64.1"
# 认证一步会增删的变量;AIBOX_ENV_VARS 里的其他项原样保留
MANAGED_ENV_NAMES="ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OPENAI_API_KEY"

usage() {
    cat <<'USAGE'
用法:
  ./setup.sh             在仓库目录里运行安装向导(还没有 aibox 命令时)
  aibox setup            运行安装向导;已完成的步骤自动跳过,可反复运行
  aibox setup --check    只检查各步骤状态,不做任何修改
USAGE
}

CHECK_ONLY=0
case "${1:-}" in
    "")        ;;
    --check)   CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_BAD=""; C_BOLD=""; C_OFF=""
fi

PENDING=()      # 尚未完成的必需项,结束时汇总
NEW_ENV=()      # 本次要写进 AIBOX_ENV_VARS 的各项
RC_CHANGED=""   # 本次改过的 shell 启动文件,结束时提示重新加载
LINK_OK=0       # ~/.local/bin/aibox 是否已指向本仓库
NEED_REBUILD=0  # 本次新放入了 gost,已有镜像需要重建
SETUP_TMP=""    # 下载、回读校验用的临时目录
CONF_TMP=""     # 正在生成的 aibox.conf,写入前被打断时清理

# shellcheck disable=SC2317 # 由 EXIT trap 调用
cleanup() {
    [[ -z "$SETUP_TMP" ]] || rm -rf -- "$SETUP_TMP"
    [[ -z "$CONF_TMP" ]] || rm -f -- "$CONF_TMP"
    return 0
}
# 显式带回原退出码:Bash 3.2 遇到 set -u 等致命错误时,退出码会被 EXIT trap 的结果覆盖成 0
# shellcheck disable=SC2154 # aibox_setup_rc 在 trap 字符串内赋值
trap 'aibox_setup_rc=$?; cleanup; exit "$aibox_setup_rc"' EXIT
trap 'printf "\n已中断。重新运行 aibox setup(或 ./setup.sh)可从未完成的步骤继续。\n" >&2; exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

# ---- 输出 ----
step() { printf '\n%s[%d/%d] %s%s\n' "$C_BOLD" "$1" "$TOTAL_STEPS" "$2" "$C_OFF"; }
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
part() { printf '\n  %s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }
pending() { PENDING+=("$1"); }

# 把 $HOME 前缀显示成 ~(只用于显示)
# shellcheck disable=SC2088
tilde() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

# ---- 输入 ----
# 统一从 stdin 读取;输入结束(EOF)时退出,避免在非交互环境里死循环。
input_closed() {
    printf '\n输入已结束,向导退出。重新运行 aibox setup(或 ./setup.sh)可从未完成的步骤继续。\n' >&2
    exit 1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ask_yn <问题> <默认 Y|N>:回答「是」返回 0
ask_yn() {
    local hint ans
    if [[ "$2" == "Y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    while true; do
        printf '  %s?%s %s %s ' "$C_BOLD" "$C_OFF" "$1" "$hint"
        IFS= read -r ans || input_closed
        case "$(trim "$ans")" in
            "")
                if [[ "$2" == "Y" ]]; then return 0; else return 1; fi
                ;;
            y|Y|yes|Yes|YES) return 0 ;;
            n|N|no|No|NO)    return 1 ;;
            *) info "请输入 y 或 n。" ;;
        esac
    done
}

# ask_line <变量名> <提示>:读一行,去掉首尾空白
ask_line() {
    local reply
    printf '  %s?%s %s' "$C_BOLD" "$C_OFF" "$2"
    IFS= read -r reply || input_closed
    printf -v "$1" '%s' "$(trim "$reply")"
}

# ask_secret <变量名> <提示>:输入不回显
ask_secret() {
    local reply
    printf '  %s?%s %s' "$C_BOLD" "$C_OFF" "$2"
    IFS= read -rs reply || { printf '\n'; input_closed; }
    printf '\n'
    printf -v "$1" '%s' "$(trim "$reply")"
}

# ask_choice <变量名> <最大编号> <默认编号>
ask_choice() {
    local reply
    while true; do
        printf '  %s?%s 请选择 [1-%s,默认 %s]: ' "$C_BOLD" "$C_OFF" "$2" "$3"
        IFS= read -r reply || input_closed
        reply="$(trim "$reply")"
        [[ -n "$reply" ]] || reply="$3"
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= $2 )); then
            printf -v "$1" '%s' "$reply"
            return 0
        fi
        info "请输入 1 到 $2 之间的数字。"
    done
}

pause_enter() {
    local reply
    printf '  %s?%s %s' "$C_BOLD" "$C_OFF" "$1"
    IFS= read -r reply || input_closed
}

# ---- 通用工具 ----
# 单引号转义,结果可原样写进 Bash 配置。不用 ${s//\'/...}:Bash 3.2 对替换串里的引号处理不同。
sq() {
    local s="$1" out=""
    while [[ "$s" == *"'"* ]]; do
        out="$out${s%%"'"*}'\\''"
        s="${s#*"'"}"
    done
    printf "'%s%s'" "$out" "$s"
}

mask_secret() {
    if (( ${#1} <= 8 )); then printf '****'; else printf '****%s' "${1: -4}"; fi
}

# 与 entrypoint 横幅同一口径:用户名和密码都不显示
mask_proxy() {
    printf '%s' "$1" | sed -E 's#(://)[^/@]*@#\1***@#'
}

proxy_label() {
    if [[ -n "$1" ]]; then mask_proxy "$1"; else printf '直连'; fi
}

# 逐层解析软链,打印真实路径(兼容 Bash 3.2,不依赖 readlink -f / realpath)
real_path() {
    local p="$1" dir target
    while [[ -h "$p" ]]; do
        dir="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)" || return 1
        target="$(readlink "$p")"
        if [[ "$target" == /* ]]; then p="$target"; else p="$dir/$target"; fi
    done
    dir="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)" || return 1
    printf '%s/%s' "$dir" "$(basename "$p")"
}

# 文件权限的八进制表示。GNU stat 的 -f 是「显示文件系统信息」,会成功并输出无关内容,
# 所以先试 GNU 的 -c,再试 BSD 的 -f,并逐个校验格式。
file_mode() {
    local m
    m="$(stat -c %a "$1" 2>/dev/null)" || m=""
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || m="$(stat -f %Lp "$1" 2>/dev/null)" || m=""
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || m=""
    printf '%s' "$m"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    fi
}

setup_tmp() {
    [[ -n "$SETUP_TMP" ]] || SETUP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aibox-setup.XXXXXX")"
}

open_url() {
    if open "$1" >/dev/null 2>&1; then
        info "已在浏览器打开 $1"
    else
        info "请在浏览器打开 $1"
    fi
}

path_has() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
    esac
    return 1
}

# 当前登录 shell 的启动文件。macOS 终端里 bash 以登录 shell 启动,读 ~/.bash_profile。
shell_rc() {
    case "$(basename "${SHELL:-}")" in
        zsh)  printf '%s' "$HOME/.zshrc" ;;
        bash) printf '%s' "$HOME/.bash_profile" ;;
        *)    return 1 ;;
    esac
}

# rc_append <文件> <行...>:追加到文件末尾;原文件末尾没有换行时先补一个
rc_append() {
    local file="$1"
    shift
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$@" >> "$file"
}

# 非登录 shell 的 PATH 可能缺 /usr/local/bin;官方安装器固定装在那里,找到就补进本进程 PATH
container_found() {
    command -v container >/dev/null 2>&1 && return 0
    if [[ -x /usr/local/bin/container ]]; then
        PATH="/usr/local/bin:$PATH"
        export PATH
        warn "container 装在 /usr/local/bin,但当前 shell 的 PATH 里没有这个目录。"
        return 0
    fi
    return 1
}

# container --version 输出形如「container CLI version 1.6.0 (build: ...)」
container_version() {
    container --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n 1
}

# version_lt A B:A 比 B 旧时返回 0(逐段比较数字,兼容 Bash 3.2)
version_lt() {
    local a="$1" b="$2" x y
    while [[ -n "$a" || -n "$b" ]]; do
        x="${a%%.*}"; y="${b%%.*}"
        x="${x:-0}"; y="${y:-0}"
        if (( 10#$x < 10#$y )); then return 0; fi
        if (( 10#$x > 10#$y )); then return 1; fi
        [[ "$a" == *.* ]] && a="${a#*.}" || a=""
        [[ "$b" == *.* ]] && b="${b#*.}" || b=""
    done
    return 1
}

# 与 aibox status 同一口径:能列容器即服务在跑
service_running() { container ls >/dev/null 2>&1; }

image_exists() { container image inspect "$1" >/dev/null 2>&1; }

container_gateway() {
    local json gw=""
    if json="$(container network inspect default 2>/dev/null)"; then
        gw="$(printf '%s' "$json" \
            | /usr/bin/plutil -extract 0.status.ipv4Gateway raw -o - - 2>/dev/null)" || gw=""
    fi
    local re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    [[ "$gw" =~ $re ]] || gw="$DEFAULT_GATEWAY"
    printf '%s' "$gw"
}

# ---- 第 1 步:Mac 环境 ----
step_host() {
    local os arch ver major
    step 1 "检查 Mac 环境"
    if [[ "$(id -u)" -eq 0 ]]; then
        bad "请不要用 sudo 或 root 运行向导;需要管理员权限的地方会单独提示。"
        exit 1
    fi
    os="$(uname -s)"
    arch="$(uname -m)"
    if [[ "$os" != "Darwin" ]]; then
        bad "aibox 只能在 macOS 上运行(当前系统: $os)。"
        exit 1
    fi
    # 终端在 Rosetta 下运行时 uname -m 报 x86_64,以硬件信息为准
    if [[ "$arch" != "arm64" && "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" != "1" ]]; then
        bad "需要 Apple silicon(M 系列芯片)Mac,当前是 $arch;Apple container 不支持 Intel Mac。"
        exit 1
    fi
    ok "Apple silicon"
    ver="$(sw_vers -productVersion 2>/dev/null || true)"
    major="${ver%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 26 )); then
        ok "macOS $ver"
    else
        warn "macOS ${ver:-版本未知}:Apple container 官方只支持 macOS 26 及以上,旧系统上可能无法正常工作。"
        if (( ! CHECK_ONLY )) && ! ask_yn "仍要继续?" N; then
            exit 1
        fi
    fi
}

# ---- 第 2 步:Apple container ----
# 下载已验证版本的官方签名安装包到 ~/Downloads,核对签名后交给系统安装器
container_pkg_open() {
    local url="$CONTAINER_PKG_URL" name pkg sig
    name="${url##*/}"
    pkg="$HOME/Downloads/$name"
    mkdir -p "$HOME/Downloads"
    info "下载 $name 到 ~/Downloads(约 150 MB)..."
    if ! curl -fL --progress-bar --max-time 1800 -o "$pkg.part" "$url"; then
        rm -f -- "$pkg.part"
        return 1
    fi
    mv -- "$pkg.part" "$pkg"
    sig="$(pkgutil --check-signature "$pkg" 2>&1)" || sig=""
    if [[ "$sig" != *"Developer ID Installer: Apple Inc."*"($CONTAINER_PKG_TEAM)"* ]]; then
        bad "安装包的签名不是 Apple 官方(团队 $CONTAINER_PKG_TEAM),已删除。"
        rm -f -- "$pkg"
        return 1
    fi
    ok "已核对签名:Apple Inc.(团队 $CONTAINER_PKG_TEAM)"
    open "$pkg"
}

step_container() {
    local ver choice
    step 2 "安装 Apple container(容器运行时)"
    while true; do
        if container_found; then
            ver="$(container_version || true)"
            if [[ -z "$ver" ]]; then
                warn "已安装,但读不到版本号(已验证版本 ${CONTAINER_TESTED_VERSION})。"
            elif version_lt "$ver" "$CONTAINER_MIN_VERSION"; then
                bad "已安装 ${ver},低于最低要求 ${CONTAINER_MIN_VERSION}。"
                info "升级方法:container system stop,再运行 /usr/local/bin/update-container.sh -v ${CONTAINER_TESTED_VERSION},"
                info "最后 container system start(升级会停止所有容器,需要管理员密码)。"
                pending "升级 Apple container 到 ${CONTAINER_TESTED_VERSION}"
            elif version_lt "$CONTAINER_TESTED_VERSION" "$ver"; then
                warn "已安装 ${ver},比已验证的 ${CONTAINER_TESTED_VERSION} 新,尚未经过验证;遇到问题请反馈。"
            elif version_lt "$ver" "$CONTAINER_TESTED_VERSION"; then
                ok "已安装 ${ver}(可以使用;已验证的最新版本是 ${CONTAINER_TESTED_VERSION},可按需升级)"
            else
                ok "已安装 ${ver}(已验证版本)"
            fi
            return 0
        fi
        bad "未找到 container 命令。"
        info "aibox 依赖 Apple 官方的 container 工具运行 Linux 容器(不是 Docker,不需要 Docker Desktop)。"
        if (( CHECK_ONLY )); then
            pending "安装 Apple container:$CONTAINER_RELEASES_URL"
            return 0
        fi
        info "1) 自动下载已验证的 ${CONTAINER_TESTED_VERSION} 官方安装包,核对 Apple 签名后打开安装器(推荐)"
        info "2) 用浏览器打开下载页,自己下载 .pkg 安装"
        info "3) 暂时跳过"
        ask_choice choice 3 1
        case "$choice" in
            1)
                if ! container_pkg_open; then
                    warn "自动下载没有成功,改为打开下载页。"
                    open_url "$CONTAINER_RELEASES_URL"
                    info "下载 container-<版本>-installer-signed.pkg 后双击安装。"
                fi
                ;;
            2)
                open_url "$CONTAINER_RELEASES_URL"
                info "下载 container-<版本>-installer-signed.pkg 后双击安装。"
                ;;
            3)
                pending "安装 Apple container:$CONTAINER_RELEASES_URL"
                return 0
                ;;
        esac
        info "安装器会要求输入管理员密码,用于把 container 装到 /usr/local。"
        pause_enter "安装完成后按回车继续检查..."
        hash -r
    done
}

# ---- 第 3 步:container 服务 ----
start_service() {
    local help
    # 带上 --enable-kernel-install,免得新手面对「是否安装默认内核」的提问不知所措;
    # 老版本没有这个参数时退回交互式提问。
    help="$(container system start --help 2>&1 || true)"
    if [[ "$help" == *"--enable-kernel-install"* ]]; then
        container system start --enable-kernel-install || true
    else
        container system start || true
    fi
}

step_service() {
    step 3 "启动 container 服务"
    if ! container_found; then
        bad "需要先完成第 2 步。"
        return 0
    fi
    if service_running; then
        ok "服务运行中"
        return 0
    fi
    bad "服务未运行。"
    if (( CHECK_ONLY )); then
        pending "启动 container 服务:container system start"
        return 0
    fi
    info "首次启动会下载 Apple 推荐的默认 Linux 内核,需要联网,可能要一两分钟。"
    if ! ask_yn "现在启动?" Y; then
        pending "启动 container 服务:container system start"
        return 0
    fi
    while true; do
        start_service
        if service_running; then
            ok "服务已启动"
            return 0
        fi
        bad "启动失败。上面是 container system start 的输出。"
        if ! ask_yn "重试?" Y; then
            pending "启动 container 服务:container system start"
            return 0
        fi
    done
}

# ---- 第 4 步:aibox 命令 ----
link_install() {
    chmod +x "$AIBOX" "$SANDBOX_DIR/entrypoint.sh" 2>/dev/null || true
    mkdir -p "$BIN_DIR"
    ln -sfn "$AIBOX" "$LINK_PATH"
    LINK_OK=1
    ok "已创建 $(tilde "$LINK_PATH") -> $(tilde "$AIBOX")"
}

# PATH 里更靠前的同名命令会遮住我们的软链
link_shadow_check() {
    local found
    hash -r
    found="$(command -v aibox 2>/dev/null || true)"
    if [[ -n "$found" && "$found" != "$LINK_PATH" \
          && "$(real_path "$found" 2>/dev/null || true)" != "$AIBOX" ]]; then
        warn "PATH 里更靠前的 $found 不是本仓库的 aibox,输入 aibox 时会先执行它。"
    fi
}

step_command() {
    local real rc
    step 4 "安装 aibox 命令"

    if [[ -L "$LINK_PATH" || -e "$LINK_PATH" ]]; then
        real="$(real_path "$LINK_PATH" 2>/dev/null || true)"
        if [[ "$real" == "$AIBOX" ]]; then
            LINK_OK=1
            ok "$(tilde "$LINK_PATH") -> $(tilde "$AIBOX")"
        else
            warn "$(tilde "$LINK_PATH") 已存在,但指向 ${real:-无法解析的位置},不是当前仓库。"
            if (( CHECK_ONLY )); then
                pending "让 $(tilde "$LINK_PATH") 指向 $(tilde "$AIBOX")"
            elif ask_yn "改为指向当前仓库?" Y; then
                link_install
            else
                pending "让 $(tilde "$LINK_PATH") 指向 $(tilde "$AIBOX")"
            fi
        fi
    else
        bad "还没有安装 aibox 命令。"
        if (( CHECK_ONLY )); then
            pending "安装 aibox 命令:ln -s $(tilde "$AIBOX") $(tilde "$LINK_PATH")"
        elif ask_yn "创建 $(tilde "$LINK_PATH")(指向仓库里的 ai-box)?" Y; then
            link_install
        else
            pending "安装 aibox 命令(在此之前可以用仓库里的 ./ai-box)"
        fi
    fi
    (( LINK_OK )) && link_shadow_check

    rc="$(shell_rc || true)"
    if path_has "$BIN_DIR"; then
        ok "$(tilde "$BIN_DIR") 已在 PATH 中"
    elif [[ -n "$rc" && -f "$rc" ]] && grep -Eq '^[^#]*\.local/bin' "$rc"; then
        ok "$(tilde "$rc") 已把 $(tilde "$BIN_DIR") 加入 PATH(新开的终端生效)"
    elif [[ -z "$rc" ]]; then
        warn "当前 shell(${SHELL:-未知})不是 zsh 或 bash,请自行把 $BIN_DIR 加入 PATH。"
        pending "把 $(tilde "$BIN_DIR") 加入 PATH"
    else
        bad "$(tilde "$BIN_DIR") 不在 PATH 中,终端里还不能直接输入 aibox。"
        if (( CHECK_ONLY )); then
            pending "把 $(tilde "$BIN_DIR") 加入 PATH"
        elif ask_yn "把它写入 $(tilde "$rc")?" Y; then
            # shellcheck disable=SC2016 # 原样写入,由 shell 启动时展开
            rc_append "$rc" "" "# aibox:把 ~/.local/bin 加入 PATH(由 aibox setup 添加)" \
                'export PATH="$HOME/.local/bin:$PATH"'
            RC_CHANGED="$rc"
            ok "已写入 $(tilde "$rc")"
        else
            pending "把 $(tilde "$BIN_DIR") 加入 PATH"
        fi
    fi

    [[ -n "$rc" ]] || return 0
    if [[ -f "$rc" ]] && grep -Eq '^[^#]*ai-box-completion\.sh' "$rc"; then
        ok "Tab 补全已配置"
    elif (( CHECK_ONLY )); then
        info "可选:Tab 补全未配置。"
    elif ask_yn "启用 Tab 补全(写入 $(tilde "$rc"))?" Y; then
        rc_append "$rc" "" "# aibox:Tab 补全(由 aibox setup 添加)" "source $(sq "$COMPLETION")"
        RC_CHANGED="$rc"
        ok "已写入 $(tilde "$rc")"
    fi
}

# ---- 第 5 步:aibox.conf ----
CUR_PROXY=""
CUR_TZ=""
CUR_LANG=""
CUR_ENV=()

# 在子 shell 里 source 配置,以 NUL 分隔输出:代理、时区、语言、AIBOX_ENV_VARS 项数及各项。
# 与 ai-box 一样直接 source —— aibox.conf 本来就会在每次启动时被 source。
conf_dump() {
    (
        set +eu
        AIBOX_PROXY=""; AIBOX_TZ=""; AIBOX_LANG=""; AIBOX_ENV_VARS=()
        # shellcheck disable=SC1090
        source "$1" >/dev/null 2>&1 </dev/null
        printf '%s\0' "$AIBOX_PROXY" "$AIBOX_TZ" "$AIBOX_LANG" "${#AIBOX_ENV_VARS[@]}"
        for entry in "${AIBOX_ENV_VARS[@]}"; do
            printf '%s\0' "$entry"
        done
    )
}

conf_load() {
    local item i=0
    CUR_PROXY=""; CUR_TZ=""; CUR_LANG=""; CUR_ENV=()
    [[ -f "$CONF" ]] || return 0
    while IFS= read -r -d '' item; do
        case "$i" in
            0) CUR_PROXY="$item" ;;
            1) CUR_TZ="$item" ;;
            2) CUR_LANG="$item" ;;
            3) ;;
            *) CUR_ENV+=("$item") ;;
        esac
        i=$((i + 1))
    done < <(conf_dump "$CONF")
}

# env_find <NAME> [项...]:在给出的 NAME=value 项里查找,值写入 REPLY_VALUE
env_find() {
    local name="$1" entry found=1
    shift
    REPLY_VALUE=""
    for entry in "$@"; do
        if [[ "$entry" == "$name="* ]]; then
            REPLY_VALUE="${entry#*=}"
            found=0
        fi
    done
    return "$found"
}

env_names() {
    local entry out=""
    for entry in "$@"; do
        out="${out:+$out, }${entry%%=*}"
    done
    printf '%s' "${out:-(无)}"
}

is_managed_env() {
    case " $MANAGED_ENV_NAMES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

conf_show() {
    info "代理    : $(proxy_label "$CUR_PROXY")"
    info "时区    : ${CUR_TZ:-跟随宿主机}"
    info "语言    : ${CUR_LANG:-跟随宿主机}"
    info "环境变量: $(env_names "${CUR_ENV[@]+"${CUR_ENV[@]}"}")"
}

gost_download() {
    local sum
    setup_tmp
    if ! curl -fL --progress-bar --max-time 600 -o "$SETUP_TMP/gost.tar.gz" "$GOST_URL"; then
        bad "下载失败。访问 GitHub 受限时,可开启代理软件的 TUN 模式后重跑向导,或手动下载。"
        return 1
    fi
    if ! tar -xzf "$SETUP_TMP/gost.tar.gz" -C "$SETUP_TMP" gost 2>/dev/null; then
        bad "解压失败,下载的文件可能不完整。"
        return 1
    fi
    sum="$(sha256_of "$SETUP_TMP/gost")"
    if [[ "$sum" != "$GOST_SHA256" ]]; then
        bad "SHA-256 不符(得到 ${sum:-空值}),已丢弃。"
        return 1
    fi
    mkdir -p "$(dirname "$GOST_PATH")"
    cp "$SETUP_TMP/gost" "$GOST_PATH"
    chmod 0755 "$GOST_PATH"
}

# 配置了代理就必须有 ~/.aibox/third_party/gost,否则容器拒绝启动
gost_ensure() {
    if [[ -f "$GOST_PATH" ]]; then
        ok "已放入 gost($(tilde "$GOST_PATH"))"
        return 0
    fi
    bad "使用代理需要 $(tilde "$GOST_PATH")(容器内的代理转换器),目前没有。"
    if (( CHECK_ONLY )); then
        pending "放入 $(tilde "$GOST_PATH") 并重建镜像(见 README「可选的 third_party 组件」)"
        return 0
    fi
    info "可以自动下载 gost $GOST_VERSION(Linux ARM64,MIT 许可证),并按 README 记录的 SHA-256 校验。"
    if ask_yn "现在下载?" Y && gost_download; then
        ok "已放入 $(tilde "$GOST_PATH")"
        NEED_REBUILD=1
        return 0
    fi
    pending "放入 gost:从 $GOST_URL 解出 gost,放到 $(tilde "$GOST_PATH") 后重建镜像"
}

# 仅在从未创建 aibox.conf 时,ai-box 才会回退到旧的 FIXED_SOCKS_* 环境变量
legacy_proxy() {
    [[ ! -f "$CONF" && -n "${FIXED_SOCKS_HOST:-}" && -n "${FIXED_SOCKS_PORT:-}" ]] || return 0
    if [[ -n "${FIXED_SOCKS_USER:-}" ]]; then
        printf 'socks5://%s:%s@%s:%s' "$FIXED_SOCKS_USER" "${FIXED_SOCKS_PASS:-}" \
            "$FIXED_SOCKS_HOST" "$FIXED_SOCKS_PORT"
    else
        printf 'socks5://%s:%s' "$FIXED_SOCKS_HOST" "$FIXED_SOCKS_PORT"
    fi
}

# proxy_ask <默认值>:结果写入 REPLY_PROXY
proxy_ask() {
    local def="$1" url rest userinfo host gw
    local re='^(https?|socks5h?)://([^[:space:]/@]+@)?[^[:space:]/@]+:[0-9]+$'
    info "格式:协议://[用户名:密码@]主机:端口,协议可以是 http、https、socks5、socks5h"
    info "例如 socks5h://user:pass@proxy.example.com:1080(socks5h 由代理端解析域名,通常优先选它)"
    info "用户名或密码里的 @ : / 等字符要做 URL 编码,例如 @ 写成 %40"
    while true; do
        if [[ -n "$def" ]]; then
            ask_line url "代理地址(回车沿用 $(mask_proxy "$def")): "
            [[ -n "$url" ]] || url="$def"
        else
            ask_line url "代理地址: "
        fi
        url="${url%/}"
        [[ "$url" =~ $re ]] && break
        bad "格式不对,请按 协议://[用户名:密码@]主机:端口 填写。"
    done

    # 容器里的 127.0.0.1 是容器自己;本机代理软件要通过宿主机在容器网络中的地址访问
    rest="${url#*://}"
    userinfo=""
    [[ "$rest" == *@* ]] && userinfo="${rest%@*}@"
    host="${rest##*@}"
    host="${host%:*}"
    case "$host" in
        localhost|127.*|0.0.0.0|::1|"[::1]")
            gw="$(container_gateway)"
            warn "容器里的 $host 指向容器自己,连不到 Mac 上的代理软件。"
            info "Mac 在容器网络中的地址是 $gw;代理软件还需要开启「允许局域网连接」(Allow LAN)。"
            if ask_yn "改用 $gw?" Y; then
                url="${url%%://*}://$userinfo$gw:${url##*:}"
                ok "代理地址改为 $(mask_proxy "$url")"
            fi
            ;;
    esac
    REPLY_PROXY="$url"
}

# 从宿主机经代理访问 Claude API,只看能否连通(任何 HTTP 状态码都算通)
proxy_probe() {
    local esc out code err
    # 代理地址经 -K - 从 stdin 交给 curl,不出现在进程参数里(其中可能有密码)
    esc="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    info "正在通过代理访问 https://api.anthropic.com ..."
    out="$(printf 'proxy = "%s"\n' "$esc" \
        | curl -sS -o /dev/null -w '\n%{http_code}' --max-time 15 -K - https://api.anthropic.com/ 2>&1)" || true
    code="$(printf '%s\n' "$out" | tail -n 1)"
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
        ok "代理可用(api.anthropic.com 返回 HTTP $code)"
    else
        err="$(printf '%s\n' "$out" | sed '$d' | head -n 1)"
        warn "无法通过代理访问:${err:-未知错误}"
        info "请检查地址、端口和账号密码。配置照样会保存,之后可以重跑 aibox setup 修改。"
    fi
}

tz_valid() {
    local re='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$'
    [[ "$1" =~ $re ]] || return 1
    [[ ! -d /usr/share/zoneinfo || -f "/usr/share/zoneinfo/$1" ]]
}

LOCALES=""
locale_valid() {
    case " $LOCALES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# env_ask <secret|plain> <NAME> <说明>:有旧值时回车沿用、输入 - 删除;结果追加进 NEW_ENV
env_ask() {
    local kind="$1" name="$2" label="$3" old="" val
    if env_find "$name" "${CUR_ENV[@]+"${CUR_ENV[@]}"}"; then
        old="$REPLY_VALUE"
        if [[ "$kind" == "secret" ]]; then
            info "$label:已配置($(mask_secret "$old"))。回车沿用,输入 - 删除,或粘贴新值。"
        else
            info "$label:已配置($old)。回车沿用,输入 - 删除,或输入新值。"
        fi
    elif [[ "$kind" == "secret" ]]; then
        info "$label:粘贴后回车(输入不会显示);不需要就直接回车跳过。"
    else
        info "$label:不需要就直接回车跳过。"
    fi
    while true; do
        if [[ "$kind" == "secret" ]]; then
            ask_secret val "$name: "
        else
            ask_line val "$name: "
        fi
        if [[ -z "$val" ]]; then
            val="$old"
        elif [[ "$val" == "-" ]]; then
            val=""
        fi
        if [[ "$kind" == "plain" && -n "$val" && ! "$val" =~ ^https?:// ]]; then
            bad "地址需要以 http:// 或 https:// 开头。"
            continue
        fi
        break
    done
    [[ -z "$val" ]] || NEW_ENV+=("$name=$val")
    return 0
}

conf_write() {
    local proxy="$1" tz="$2" lang="$3" env_block="" entry backup=""
    for entry in "${NEW_ENV[@]+"${NEW_ENV[@]}"}"; do
        env_block="$env_block  $(sq "$entry")"$'\n'
    done
    # 以 aibox.conf.example 为模板,只替换取值行,注释说明与示例保持同步
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    CONF_TMP="$(mktemp "$CONF.tmp.XXXXXX")"
    chmod 600 "$CONF_TMP"
    {
        printf '# 由 aibox setup 生成于 %s。可以直接编辑,也可以重跑 aibox setup 修改。\n#\n' \
            "$(date '+%Y-%m-%d %H:%M')"
        W_PROXY="$(sq "$proxy")" W_TZ="$(sq "$tz")" W_LANG="$(sq "$lang")" W_ENV="$env_block" \
            awk '
                /^AIBOX_PROXY=/      { print "AIBOX_PROXY=" ENVIRON["W_PROXY"]; next }
                /^AIBOX_TZ=/         { print "AIBOX_TZ=" ENVIRON["W_TZ"]; next }
                /^AIBOX_LANG=/       { print "AIBOX_LANG=" ENVIRON["W_LANG"]; next }
                /^AIBOX_ENV_VARS=\(/ { in_env = 1 }
                in_env && /^\)/      { printf "%s", ENVIRON["W_ENV"]; in_env = 0 }
                { print }
            ' "$CONF_EXAMPLE"
    } > "$CONF_TMP"

    # 回读校验:按 ai-box 的方式 source 新文件,取到的值必须与输入逐字一致
    setup_tmp
    {
        printf '%s\0' "$proxy" "$tz" "$lang" "${#NEW_ENV[@]}"
        for entry in "${NEW_ENV[@]+"${NEW_ENV[@]}"}"; do
            printf '%s\0' "$entry"
        done
    } > "$SETUP_TMP/conf.expected"
    conf_dump "$CONF_TMP" > "$SETUP_TMP/conf.actual"
    if ! bash -n "$CONF_TMP" 2>/dev/null \
       || ! cmp -s "$SETUP_TMP/conf.expected" "$SETUP_TMP/conf.actual"; then
        bad "生成的配置回读校验失败,没有写入。"
        pending "创建 aibox.conf:cp aibox.conf.example aibox.conf 后手动编辑"
        return 0
    fi

    if [[ -f "$CONF" ]]; then
        backup="$CONF.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$CONF" "$backup"
        chmod 600 "$backup"
    fi
    mv -f -- "$CONF_TMP" "$CONF"
    CONF_TMP=""
    ok "已写入 $(tilde "$CONF")(权限 600)"
    [[ -z "$backup" ]] || info "原配置已备份到 $(tilde "$backup")"
    return 0
}

conf_wizard() {
    local proxy="" tz="" lang="" choice def legacy host_tz host_lang entry removed=""

    part "① 网络代理"
    info "1) 直连:网络能直接访问 Claude / OpenAI,或者 Mac 上的代理软件已开启 TUN(增强)模式"
    info "2) 上游代理:容器流量全部经指定代理出去(HTTP / HTTPS / SOCKS5),例如固定住宅 IP"
    legacy="$(legacy_proxy)"
    def=1
    [[ -z "$CUR_PROXY$legacy" ]] || def=2
    ask_choice choice 2 "$def"
    if [[ "$choice" == 2 ]]; then
        proxy_ask "${CUR_PROXY:-$legacy}"
        proxy="$REPLY_PROXY"
        gost_ensure
        if ask_yn "测试能否通过这个代理访问 Claude API?" Y; then
            proxy_probe "$proxy"
        fi
    fi

    part "② 时区"
    host_tz="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')"
    info "留空 = 跟随宿主机${host_tz:+(当前 $host_tz)};也可以填 IANA 时区名,如 Asia/Shanghai、America/Los_Angeles、UTC"
    while true; do
        if [[ -n "$CUR_TZ" ]]; then
            ask_line tz "时区(回车沿用 $CUR_TZ,输入 - 改为跟随宿主机): "
            [[ -n "$tz" ]] || tz="$CUR_TZ"
        else
            ask_line tz "时区(回车跟随宿主机): "
        fi
        [[ "$tz" != "-" ]] || tz=""
        if [[ -z "$tz" ]] || tz_valid "$tz"; then
            break
        fi
        bad "找不到时区 ${tz}。"
    done

    part "③ 语言"
    LOCALES="C.UTF-8 $(sed -n 's/^ARG LOCALE_GEN="\(.*\)"$/\1/p' "$SANDBOX_DIR/Dockerfile" 2>/dev/null || true)"
    host_lang="${LANG:-}"
    info "留空 = 跟随宿主机${host_lang:+(当前 $host_lang)}。镜像内可用:"
    info "$LOCALES"
    if [[ -n "$host_lang" ]] && ! locale_valid "$host_lang"; then
        warn "宿主机的 $host_lang 不在列表里,跟随宿主机时容器会回退到 C.UTF-8。"
    fi
    while true; do
        if [[ -n "$CUR_LANG" ]]; then
            ask_line lang "语言(回车沿用 $CUR_LANG,输入 - 改为跟随宿主机): "
            [[ -n "$lang" ]] || lang="$CUR_LANG"
        else
            ask_line lang "语言(回车跟随宿主机): "
        fi
        [[ "$lang" != "-" ]] || lang=""
        if [[ -z "$lang" ]] || locale_valid "$lang"; then
            break
        fi
        bad "镜像里没有 $lang,请从上面的列表中选择。"
    done

    part "④ Claude Code / Codex 认证"
    info "1) 账号登录(推荐):首次运行 aibox cc / aibox codex 时按提示在浏览器登录;登录状态保存在 ~/.aibox/,"
    info "   长期容器和临时容器共用,长期有效"
    info "2) API key:写进 aibox.conf,每次启动时以环境变量传入容器(按量计费或中转服务)"
    NEW_ENV=()
    for entry in "${CUR_ENV[@]+"${CUR_ENV[@]}"}"; do
        if is_managed_env "${entry%%=*}"; then
            removed="${removed:+$removed, }${entry%%=*}"
        else
            NEW_ENV+=("$entry")
        fi
    done
    def=1
    [[ -z "$removed" ]] || def=2
    ask_choice choice 2 "$def"
    if [[ "$choice" == 2 ]]; then
        env_ask secret ANTHROPIC_API_KEY "Claude(Anthropic)API key"
        env_ask plain ANTHROPIC_BASE_URL "Claude API 地址(用中转服务时填写,官方 API 留空)"
        env_ask secret OPENAI_API_KEY "OpenAI API key(Codex 用)"
    elif [[ -n "$removed" ]]; then
        warn "aibox.conf 里已有 $removed;选择账号登录时,CLI 会优先使用环境变量里的 key。"
        if ! ask_yn "从配置中移除它们?" Y; then
            for entry in "${CUR_ENV[@]}"; do
                if is_managed_env "${entry%%=*}"; then
                    NEW_ENV+=("$entry")
                fi
            done
        fi
    fi

    echo
    info "即将写入 $(tilde "$CONF"):"
    info "  代理    : $(proxy_label "$proxy")"
    info "  时区    : ${tz:-跟随宿主机}"
    info "  语言    : ${lang:-跟随宿主机}"
    info "  环境变量: $(env_names "${NEW_ENV[@]+"${NEW_ENV[@]}"}")"
    if [[ -f "$CONF" ]]; then
        info "原文件会先备份;其中手写的注释和其他 shell 代码不会带到新文件。"
    fi
    if ! ask_yn "确认写入?" Y; then
        info "没有写入,配置保持不变。"
        return 0
    fi
    conf_write "$proxy" "$tz" "$lang"
}

step_config() {
    local mode
    step 5 "运行配置 aibox.conf(代理 / 时区 / 语言 / 认证)"
    if [[ ! -f "$CONF_EXAMPLE" ]]; then
        bad "缺少 aibox.conf.example,仓库文件不完整。"
        pending "重新克隆仓库后再运行向导"
        return 0
    fi

    [[ -z "$LEGACY_NOTE" ]] || info "$LEGACY_NOTE"
    if [[ -f "$CONF" ]]; then
        if ! bash -n "$CONF" 2>/dev/null; then
            bad "$(tilde "$CONF") 有 Bash 语法错误,aibox 启动时会失败。"
            if (( CHECK_ONLY )); then
                pending "修正 aibox.conf 的语法错误(或重跑 aibox setup 重新生成)"
            elif ask_yn "重新生成?(原文件会先备份)" Y; then
                conf_wizard
            else
                pending "修正 aibox.conf 的语法错误"
            fi
            return 0
        fi
        conf_load
        ok "已有配置 $(tilde "$CONF")"
        conf_show
        mode="$(file_mode "$CONF")"
        if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
            warn "文件权限为 $mode,本机其他用户也能读取;其中可能有 API key 或代理密码。"
            if (( CHECK_ONLY )); then
                info "建议执行 chmod 600 $(tilde "$CONF")"
            elif ask_yn "改为仅自己可读写(chmod 600)?" Y; then
                chmod 600 "$CONF"
                ok "已改为 600"
            fi
        fi
    else
        info "还没有 aibox.conf。全部用默认值(直连、时区和语言跟随宿主机、容器内账号登录)时可以不创建。"
    fi

    if (( CHECK_ONLY )); then
        [[ -z "$CUR_PROXY" ]] || gost_ensure
        return 0
    fi
    if [[ -f "$CONF" ]]; then
        if ask_yn "修改配置?" N; then
            conf_wizard
        elif [[ -n "$CUR_PROXY" ]]; then
            gost_ensure
        fi
    elif ask_yn "现在创建配置?" Y; then
        conf_wizard
    fi
}

# ---- 第 6 步:迁移旧版数据 ----
# 旧版的 Claude / Codex 状态在仓库 creds/(临时容器)和长期容器机内(/home/<用户>/.claude)。
# 具体检测和复制由 aibox migrate 完成;这里只判断要不要做,--check 时不为检查去启动长期容器。
step_migrate() {
    local legacy="" entry
    step 6 "迁移旧版数据(登录状态与配置)"
    if [[ -f "$MIGRATED_MARK" ]]; then
        ok "已完成($(cat "$MIGRATED_MARK"))"
        return 0
    fi
    for entry in "$SANDBOX_DIR"/creds/* "$SANDBOX_DIR"/creds/.[!.]*; do
        if [[ -e "$entry" && "$(basename "$entry")" != ".DS_Store" ]]; then
            legacy="仓库 creds/"
            break
        fi
    done
    if container_found && service_running \
       && container machine list -q 2>/dev/null | grep -qxF "$DEV_MACHINE_NAME"; then
        legacy="${legacy:+${legacy}、}已有的长期容器"
    fi
    if [[ -z "$legacy" ]]; then
        ok "没有旧版数据,无需迁移"
        return 0
    fi
    warn "发现可能含旧版数据的位置:${legacy}。新版两种容器共用 ~/.aibox/。"
    if (( CHECK_ONLY )); then
        pending "迁移旧版登录状态与配置:aibox migrate"
        return 0
    fi
    info "两边都有数据时可以选用长期容器的、临时容器的,或者合并;只复制,原数据保留。"
    if ask_yn "现在迁移?" Y; then
        if ! bash "$AIBOX" migrate; then
            pending "迁移旧版登录状态与配置:aibox migrate"
        fi
    else
        info "下次启动 aibox 时也会再问。"
        pending "迁移旧版登录状态与配置:aibox migrate"
    fi
}

# ---- 第 7 步:镜像 ----
# run_build <说明> <ai-box 参数...>:失败时给出常见原因并询问重试
run_build() {
    local desc="$1"
    shift
    while true; do
        echo
        if bash "$AIBOX" "$@"; then
            ok "$desc 完成"
            return 0
        fi
        bad "$desc 失败。常见原因:"
        info "· 报 -9816 或 server closed session:运行 container builder delete --force 后重试"
        info "· 下载超时:构建不经过 aibox.conf 里的代理,网络受限时可开启代理软件的 TUN 模式后重试"
        if ! ask_yn "重试?" Y; then
            pending "$desc:aibox $*"
            return 1
        fi
    done
}

step_build() {
    local missing=""
    step 7 "构建镜像"
    if ! container_found || ! service_running; then
        bad "需要先完成第 2、3 步(安装并启动 Apple container)。"
        pending "构建镜像:aibox build"
        return 0
    fi
    # 默认的长期容器用 $DEV_IMAGE,它以临时容器所用的 $IMAGE 为底,两个都需要
    image_exists "$IMAGE" || missing="$IMAGE"
    image_exists "$DEV_IMAGE" || missing="${missing:+${missing}、}$DEV_IMAGE"
    if [[ -z "$missing" ]] && (( ! NEED_REBUILD )); then
        ok "已构建 $IMAGE 和 $DEV_IMAGE"
        return 0
    fi
    if [[ -z "$missing" ]]; then
        warn "本次新放入了 gost,需要重建镜像,临时容器的代理才能生效(已有的长期容器启动时会自动同步 gost)。"
    else
        bad "还没有构建 ${missing}。"
    fi
    if (( CHECK_ONLY )); then
        pending "构建镜像:aibox build"
        return 0
    fi
    info "aibox build 会依次构建基础镜像和长期容器镜像,需要联网下载 node:22-bookworm、系统包和"
    info "Claude Code / Codex,首次通常需要 5~15 分钟。"
    if ask_yn "现在构建?" Y; then
        run_build "构建镜像" build || true
    else
        pending "构建镜像:aibox build"
    fi
}

# ---- 第 8 步:剪贴板贴图 ----
step_clip() {
    step 8 "剪贴板贴图(可选)"
    if launchctl print "gui/$(id -u)/$CLIP_LABEL" >/dev/null 2>&1; then
        ok "已启用(沙箱里按 Ctrl+V 粘贴 Mac 剪贴板里的图片)"
        return 0
    fi
    info "启用后,沙箱里的 Claude Code 可以用 Ctrl+V 粘贴 Mac 剪贴板里的截图。"
    info "做法是在 Mac 上常驻一个轻量监听,只镜像图片、不镜像文字;随时可用 aibox clip uninstall 关闭。"
    if (( CHECK_ONLY )); then
        info "未启用。需要时运行 aibox clip install。"
        return 0
    fi
    if ask_yn "启用?" N; then
        if bash "$AIBOX" clip install; then
            ok "已启用"
        else
            warn "启用失败,可以运行 aibox clip doctor 排查。"
        fi
    fi
}

finish() {
    local item cmd="aibox"
    echo
    if (( ${#PENDING[@]} == 0 )); then
        printf '%s%s全部就绪。%s\n' "$C_OK" "$C_BOLD" "$C_OFF"
    else
        printf '%s%s还有 %d 项未完成:%s\n' "$C_WARN" "$C_BOLD" "${#PENDING[@]}" "$C_OFF"
        for item in "${PENDING[@]}"; do
            info "· $item"
        done
        info "处理后重跑 aibox setup(或 ./setup.sh)即可继续。"
    fi
    if (( ! CHECK_ONLY )); then
        (( LINK_OK )) || cmd="$(tilde "$AIBOX")"
        echo
        echo "接下来:"
        if [[ -n "$RC_CHANGED" ]]; then
            info "先新开一个终端窗口(或执行 source $(tilde "$RC_CHANGED")),让 aibox 命令生效"
        fi
        info "cd ~/your-project"
        info "$cmd cc        # 在长期容器里启动 Claude Code(首次会提示登录)"
        info "$cmd codex     # 在长期容器里启动 Codex"
        info "$cmd           # 只进入长期容器的 shell"
        info "$cmd tmp cc    # 改用用完即删的临时容器(只挂载当前项目,适合不完全信任的代码)"
        info "$cmd help      # 全部命令;要调整配置,随时重跑 $cmd setup"
    fi
    (( ${#PENDING[@]} == 0 ))
}

main() {
    local version
    version="$(sed -n 's/^AIBOX_VERSION="\(.*\)"$/\1/p' "$AIBOX" 2>/dev/null | head -n 1)"
    printf '%saibox 安装向导%s%s\n' "$C_BOLD" "${version:+ v$version}" "$C_OFF"
    if (( CHECK_ONLY )); then
        info "只检查,不做任何修改。"
    else
        info "依次完成:检查 Mac 环境 → 安装 Apple container → 启动服务 → 安装 aibox 命令"
        info "          → 运行配置 → 迁移旧版数据 → 构建镜像 → 剪贴板贴图(可选)"
        info "已完成的步骤会自动跳过;随时可以 Ctrl+C 退出,重新运行会从未完成处继续。"
    fi
    if (( CHECK_ONLY )); then
        # 不做修改:旧位置的文件就地读取,并提示下次运行 aibox 时会搬走
        if [[ ! -f "$CONF" && -f "$LEGACY_CONF" && ! -L "$LEGACY_CONF" ]]; then
            CONF="$LEGACY_CONF"
            LEGACY_NOTE="配置还在旧位置 $(tilde "$LEGACY_CONF"),下次运行 aibox 时会自动移到 ~/.aibox/。"
        fi
        if [[ ! -f "$GOST_PATH" && -f "$LEGACY_GOST" ]]; then
            GOST_PATH="$LEGACY_GOST"
        fi
    fi
    step_host
    if (( ! CHECK_ONLY )); then
        # 确认是在 Mac 上之后,先把旧版放在程序目录里的配置、third_party、缓存搬到 ~/.aibox
        bash "$AIBOX" __relocate-state || true
    fi
    step_container
    step_service
    step_command
    step_config
    step_migrate
    step_build
    step_clip
    if finish; then
        exit 0
    fi
    exit 1
}

main
