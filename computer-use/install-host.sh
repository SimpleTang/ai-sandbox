#!/bin/bash
# install-host.sh —— Mac 应用控制(computer use)的宿主机侧(macOS)
#
# 一般不直接调用,走 ai-box 的子命令:
#   aibox cu install      安装 CuaDriver、引导授权、启动网关、写入 claude / codex 的 MCP 配置
#   aibox cu status       查看状态
#   aibox cu doctor       逐项诊断
#   aibox cu apps         列出「总是允许」的应用;allow <应用> / revoke <应用> 增删
#   aibox cu off | on     急停 / 恢复
#   aibox cu update       升级到 aibox 锁定的 CuaDriver 版本
#   aibox cu restart      重新生成并加载网关(升级 aibox 后用)
#   aibox cu uninstall    卸载
#
# 架构、安全模型见同目录 README.md。容器侧的转发器 aibox-mac-mcp 由 aibox 启动容器时放进去,
# 不需要重建镜像。
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "错误: 这个脚本要在 macOS 宿主机上跑,不是在沙箱里。" >&2
	exit 1
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 由 ai-box 传入;直接运行时按程序目录推算
STATE_DIR="${AIBOX_STATE_DIR:-$HOME/.aibox}"
PROG_DIR="${AIBOX_STABLE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PORT="${AIBOX_CU_PORT:-47123}"
if [[ ! "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( PORT > 65535 )); then
	echo "错误: AIBOX_CU_PORT='$PORT' 不是合法端口。" >&2
	exit 2
fi

CU_DIR="$STATE_DIR/cu"
CLIENT_DIR="$CU_DIR/client"
DISABLED_MARK="$CU_DIR/disabled"
GATEWAY="$PROG_DIR/computer-use/gateway.py"
PY=/usr/bin/python3
LABEL="com.aibox.cu-gateway"
PLIST_SRC="$SCRIPT_DIR/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/aibox-cu"
DOMAIN="gui/$(id -u)"
APP="/Applications/CuaDriver.app"
DRIVER="$APP/Contents/MacOS/cua-driver"

# CuaDriver(trycua/cua 的 cua-driver-rs,MIT)锁定版本。升级时三项一起改,并跑一遍
# README「验证」一节的端到端测试。SHA-256 对应 darwin-arm64 包;Team ID 来自 codesign。
CUA_VERSION="0.38.0"
CUA_SHA256="5f71191c082ca07c9dfc13b7c9a6eec60a82818c245a93534cc0eb7911471d72"
CUA_TEAM="YCK386LBJ7"
CUA_URL="https://github.com/trycua/cua/releases/download/cua-driver-rs-v${CUA_VERSION}/cua-driver-rs-${CUA_VERSION}-darwin-arm64.tar.gz"

# shellcheck source=../aibox-ui.sh
source "$SCRIPT_DIR/../aibox-ui.sh"

if [[ -t 1 ]]; then
	C_OK=$'\033[32m' C_BAD=$'\033[31m' C_WARN=$'\033[33m' C_OFF=$'\033[0m'
else
	C_OK="" C_BAD="" C_WARN="" C_OFF=""
fi
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
tilde() { local mark='~'; printf '%s' "${1/#$HOME/$mark}"; }

CU_TMP=""
cu_cleanup() { [[ -z "$CU_TMP" ]] || rm -rf -- "$CU_TMP"; }
trap cu_cleanup EXIT

run_dir() {
	local tmp
	tmp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
	printf '%saibox-cu' "${tmp:-${TMPDIR:-/tmp/}}"
}

# 容器网络里宿主机的地址,与安装向导的 container_gateway() 同源
gateway_ip() {
	local json gw=""
	if command -v container >/dev/null 2>&1 && json="$(container network inspect default 2>/dev/null)"; then
		gw="$(printf '%s' "$json" | /usr/bin/plutil -extract 0.status.ipv4Gateway raw -o - - 2>/dev/null)" || gw=""
	fi
	[[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || gw="192.168.64.1"
	printf '%s' "$gw"
}

python_ok() {
	# 没装命令行工具(CLT)时 /usr/bin/python3 只是个会弹安装框的占位程序
	xcode-select -p >/dev/null 2>&1 &&
		"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1
}

driver_version() {
	/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true
}

team_of() {
	codesign -dv --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}

app_trusted() {
	[[ -d "$1" ]] && codesign --verify --deep --strict "$1" >/dev/null 2>&1 && [[ "$(team_of "$1")" == "$CUA_TEAM" ]]
}

agent_loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

agent_pid() {
	launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk -F'= *' '/^[[:space:]]*pid =/ { print $2; exit }'
}

listening() {
	/usr/bin/nc -z -G 2 "$(endpoint_host)" "$PORT" >/dev/null 2>&1
}

endpoint_host() {
	local ep
	ep="$(cat "$CLIENT_DIR/endpoint" 2>/dev/null || true)"
	if [[ -n "$ep" ]]; then
		printf '%s' "${ep%:*}"
	else
		gateway_ip
	fi
}

# ---- 安装 CuaDriver.app ----
install_driver() {
	local have tarball src
	have="$(driver_version)"
	if [[ "$have" == "$CUA_VERSION" ]] && app_trusted "$APP"; then
		ok "CuaDriver $CUA_VERSION 已安装,签名正确"
		return 0
	fi
	if [[ -d "$APP" && "$have" != "$CUA_VERSION" ]]; then
		warn "已有 $APP(版本 ${have:-未知}),aibox 需要的是 ${CUA_VERSION}。"
		ui_yn "替换成 $CUA_VERSION?" Y || { bad "保留现有版本,未继续安装。"; return 1; }
	fi
	CU_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aibox-cu.XXXXXX")"
	if [[ -n "${AIBOX_CU_TARBALL:-}" ]]; then
		tarball="$AIBOX_CU_TARBALL"
		info "使用本地文件 $(tilde "$tarball")"
	else
		tarball="$CU_TMP/cua-driver.tar.gz"
		info "下载 CuaDriver $CUA_VERSION(约 85 MB,来自 GitHub trycua/cua)..."
		if ! curl -fL --progress-bar --max-time 1800 -o "$tarball" "$CUA_URL"; then
			bad "下载失败。访问 GitHub 受限时,可开启代理软件的 TUN 模式后重试;"
			info "或手动下载 $CUA_URL,"
			info "再用 AIBOX_CU_TARBALL=<下载的文件> aibox cu install 安装。"
			return 1
		fi
	fi
	if [[ "$(shasum -a 256 "$tarball" | awk '{print $1}')" != "$CUA_SHA256" ]]; then
		bad "SHA-256 不符,已丢弃。期望 ${CUA_SHA256}。"
		return 1
	fi
	mkdir -p "$CU_TMP/x"
	tar -xzf "$tarball" -C "$CU_TMP/x"
	src="$(find "$CU_TMP/x" -maxdepth 3 -type d -name CuaDriver.app | head -n 1)"
	if [[ -z "$src" ]] || ! app_trusted "$src"; then
		bad "包里的 CuaDriver.app 签名校验失败(要求 Team ID $CUA_TEAM),已丢弃。"
		return 1
	fi
	# 先停掉所有用旧二进制跑着的进程,再替换
	stop_driver_daemons all
	if [[ -d "$APP" ]]; then
		mv "$APP" "$CU_TMP/CuaDriver.old.app"
	fi
	if ! ditto "$src" "$APP" || ! app_trusted "$APP"; then
		rm -rf "$APP"
		[[ ! -d "$CU_TMP/CuaDriver.old.app" ]] || mv "$CU_TMP/CuaDriver.old.app" "$APP"
		bad "复制到 /Applications 失败,已恢复原状。"
		return 1
	fi
	ok "已安装 CuaDriver $CUA_VERSION 到 $APP(Developer ID 签名,Team ID $CUA_TEAM)"
}

# 停掉网关专用的驱动实例;带 all 时连用户自己的默认实例也停(只在替换 CuaDriver.app 时需要)
stop_driver_daemons() {
	local rd
	rd="$(run_dir)"
	[[ -x "$DRIVER" ]] || return 0
	"$DRIVER" stop --socket "$rd/cua.sock" --pid-file "$rd/cua.pid" >/dev/null 2>&1 || true
	if [[ "${1:-}" == "all" ]]; then
		"$DRIVER" stop >/dev/null 2>&1 || true
	fi
}

# 默认实例是不是已经在跑(用户自己在用 CuaDriver 时,aibox 不去停它)
default_daemon_running() {
	[[ -x "$DRIVER" ]] && "$DRIVER" status >/dev/null 2>&1
}

# ---- 系统权限:屏幕录制 + 辅助功能,只授给 CuaDriver.app ----
# 只读的 permissions status 需要一个以 CuaDriver 身份运行的常驻进程才能如实回答,
# 所以临时起一个默认实例问一下,问完停掉。
permissions_granted() {
	local out i was_running=0
	default_daemon_running && was_running=1
	if (( ! was_running )); then
		open -g -a "$APP" --env CUA_DRIVER_RS_UPDATE_CHECK=0 --args serve >/dev/null 2>&1 || return 1
		for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
			"$DRIVER" status >/dev/null 2>&1 && break
			sleep 0.25
		done
	fi
	out="$("$DRIVER" permissions status 2>&1 || true)"
	(( was_running )) || "$DRIVER" stop >/dev/null 2>&1 || true
	[[ "$out" == *"Accessibility:"*"granted"* && "$out" == *"Screen Recording:"*"granted"* ]] &&
		[[ "$out" != *"not granted"* && "$out" != *"denied"* ]]
}

ensure_permissions() {
	if permissions_granted; then
		ok "CuaDriver 已有辅助功能和屏幕录制权限"
		return 0
	fi
	warn "需要给 CuaDriver 授权:辅助功能、屏幕录制(macOS 26 还会多问一次「直接访问屏幕」)。"
	info "接下来会弹出 CuaDriver 的窗口和系统设置,按提示打开开关。"
	info "系统提示「退出并重新打开」时点它;卡住不动时按 Ctrl+C,再重跑 aibox cu install。"
	info "授权只针对 CuaDriver.app;aibox 的网关和容器都拿不到这两项权限。"
	ui_yn "开始授权?" Y || { bad "未授权,Mac 应用控制暂时不能用。"; return 1; }
	local was_running=0
	default_daemon_running && was_running=1
	if "$DRIVER" permissions grant; then
		(( was_running )) || "$DRIVER" stop >/dev/null 2>&1 || true
		ok "授权完成"
	else
		(( was_running )) || "$DRIVER" stop >/dev/null 2>&1 || true
		bad "授权没有完成。授权完后重跑 aibox cu install。"
		return 1
	fi
}

# ---- token 与端点:容器侧转发器从这里读(临时容器由 aibox 以环境变量传入)----
ensure_client() {
	local ip
	ip="$(gateway_ip)"
	mkdir -p "$CLIENT_DIR"
	chmod 0700 "$CU_DIR" "$CLIENT_DIR"
	if [[ ! -s "$CLIENT_DIR/token" ]]; then
		(umask 077; /usr/bin/openssl rand -hex 32 > "$CLIENT_DIR/token")
	fi
	chmod 0600 "$CLIENT_DIR/token"
	printf '%s:%s\n' "$ip" "$PORT" > "$CLIENT_DIR/endpoint"
	touch "$CU_DIR/allowed-apps"
}

# ---- 网关 LaunchAgent ----
render_plist() {
	local ip value
	ip="$(gateway_ip)"
	# 下面的值会经 sed 写进 XML:不允许含 sed 分隔符和 XML 特殊字符
	for value in "$PY" "$GATEWAY" "$CU_DIR" "$APP" "$LOG_DIR"; do
		case "$value" in
			*'|'*|*'&'*|*'<'*|*'>'*|*'\'*)
				echo "错误: 路径 $value 含有 | & < > \\ 等字符,无法写进 LaunchAgent。" >&2
				exit 1 ;;
		esac
	done
	mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
	# gateway.log 由 launchd 追加写,这里封顶 1 MB
	if [[ -f "$LOG_DIR/gateway.log" ]] && (( $(wc -c < "$LOG_DIR/gateway.log") > 1048576 )); then
		mv "$LOG_DIR/gateway.log" "$LOG_DIR/gateway.log.1"
	fi
	sed -e "s|__PYTHON__|$PY|g" -e "s|__GATEWAY__|$GATEWAY|g" -e "s|__STATE__|$CU_DIR|g" \
		-e "s|__BIND__|$ip|g" -e "s|__PORT__|$PORT|g" -e "s|__APP__|$APP|g" \
		-e "s|__LOGDIR__|$LOG_DIR|g" "$PLIST_SRC" > "$PLIST_DST"
	if ! /usr/bin/plutil -lint "$PLIST_DST" >/dev/null; then
		echo "错误: 生成的 $PLIST_DST 不是合法的 plist。" >&2
		exit 1
	fi
}

unload_agent() {
	local n=0
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	# bootout 是异步的,等它真的卸载完,否则紧接着的 bootstrap 会报 5: Input/output error
	while agent_loaded; do
		n=$((n + 1))
		if (( n > 50 )); then
			echo "错误: $LABEL 在 5 秒内没有卸载完成,试试 launchctl bootout ${DOMAIN}/${LABEL}。" >&2
			exit 1
		fi
		sleep 0.1
	done
}

load_agent() {
	local n=0 err
	unload_agent
	err="$(mktemp "${TMPDIR:-/tmp}/aibox-cu-bootstrap.XXXXXX")"
	until launchctl bootstrap "$DOMAIN" "$PLIST_DST" 2>"$err"; do
		n=$((n + 1))
		if (( n >= 3 )); then
			echo "错误: 无法加载 $LABEL" >&2
			sed 's/^/      /' "$err" >&2
			rm -f "$err"
			exit 1
		fi
		sleep 0.5
	done
	rm -f "$err"
	launchctl enable "$DOMAIN/$LABEL"
}

wait_listening() {
	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		listening && return 0
		sleep 0.25
	done
	return 1
}

register_mcp() {
	local line
	while IFS= read -r line; do
		ok "已写入 MCP 配置 —— $line"
	done < <("$PY" "$GATEWAY" register --claude-dir "$STATE_DIR/claude" --codex-dir "$STATE_DIR/codex")
}

# ---- 子命令 ----
do_install() {
	echo "== 安装 Mac 应用控制(computer use) =="
	if [[ "$(uname -m)" != "arm64" ]]; then
		bad "只支持 Apple silicon Mac。"
		exit 1
	fi
	if ! python_ok; then
		bad "需要命令行工具(CLT)自带的 /usr/bin/python3(3.9 以上),网关用它运行。"
		info "运行 xcode-select --install 安装后重试。"
		exit 1
	fi
	[[ -f "$GATEWAY" ]] || { bad "找不到 $GATEWAY"; exit 1; }
	install_driver || exit 1
	"$DRIVER" telemetry disable >/dev/null 2>&1 && ok "已关闭 CuaDriver 的遥测" || warn "关闭遥测失败,可手动运行 $DRIVER telemetry disable"
	ensure_permissions || exit 1
	ensure_client
	ok "网关 token 在 $(tilde "$CLIENT_DIR")(只有你和容器能读)"
	rm -f "$DISABLED_MARK"
	render_plist
	load_agent
	if wait_listening; then
		ok "网关已启动,监听 $(endpoint_host):$PORT"
	else
		warn "网关已启动,但 $(endpoint_host):$PORT 还没开始监听。"
		info "容器网络的网卡在第一个容器启动后才出现,网关会自动重试;之后可用 aibox cu status 确认。"
	fi
	register_mcp
	echo
	echo "完成。接下来:"
	info "重启正在运行的 Claude Code / Codex,它们会多出一个名为 mac 的 MCP 服务。"
	info "让 AI 操作某个应用时,它会先申请授权,Mac 上会弹出确认框(拒绝 / 仅本次会话 / 总是允许)。"
	info "终端、IDE、浏览器、Finder、系统设置等被禁止控制;随时可用 aibox cu off 急停。"
}

do_restart() {
	[[ -f "$PLIST_DST" ]] || { echo "尚未安装,先运行 aibox cu install" >&2; exit 1; }
	ensure_client
	rm -f "$DISABLED_MARK"
	render_plist
	load_agent
	if wait_listening; then
		echo "网关已重新加载,监听 $(endpoint_host):$PORT"
	else
		echo "网关已重新加载;容器网络就绪后开始监听(aibox cu status 查看)"
	fi
}

do_off() {
	unload_agent
	stop_driver_daemons
	if [[ -d "$CU_DIR" ]]; then
		: > "$DISABLED_MARK"
	fi
	echo "已急停:网关和 CuaDriver 都已停止,容器里的 mac 服务会报告不可用。aibox cu on 恢复。"
}

do_on() {
	[[ -f "$PLIST_DST" ]] || { echo "尚未安装,先运行 aibox cu install" >&2; exit 1; }
	rm -f "$DISABLED_MARK"
	load_agent
	if wait_listening; then
		echo "已恢复,网关监听 $(endpoint_host):${PORT}。正在运行的 Claude Code / Codex 需要重启才会重新连上。"
	else
		echo "已恢复;容器网络就绪后开始监听。"
	fi
}

do_uninstall() {
	echo "== 卸载 Mac 应用控制 =="
	unload_agent
	rm -f "$PLIST_DST"
	stop_driver_daemons
	ok "网关已停止并移除"
	if python_ok && [[ -f "$GATEWAY" ]]; then
		"$PY" "$GATEWAY" unregister --claude-dir "$STATE_DIR/claude" --codex-dir "$STATE_DIR/codex"
		ok "已从 Claude Code / Codex 的配置里移除 mac 服务"
	fi
	if [[ -d "$CU_DIR" ]]; then
		if ui_yn "删除 token 和「总是允许」的应用清单($(tilde "$CU_DIR"))?" Y; then
			rm -rf "$CU_DIR"
			ok "已删除 $(tilde "$CU_DIR")"
		fi
	fi
	if [[ -d "$APP" ]] && ui_yn "同时删除 CuaDriver.app 及其数据(~/.cua-driver、~/Library/Caches/cua-driver)?" N; then
		rm -rf "$APP" "$HOME/.cua-driver" "$HOME/Library/Caches/cua-driver"
		ok "已删除 CuaDriver"
		info "系统设置里给 CuaDriver 的权限条目可以手动删掉:隐私与安全性 → 辅助功能 / 屏幕录制与系统录音。"
	fi
	echo "已卸载。容器里的 aibox-mac-mcp 会报告不可用,不影响其他功能。"
}

# 字段宽度与 aibox status 保持一致
field() { printf '  %s : %s\n' "$1" "$2"; }

granted_count() {
	grep -c -v -E '^[[:space:]]*(#|$)' "$CU_DIR/allowed-apps" 2>/dev/null || true
}

do_status() {
	local have pid verdict advice="" n
	have="$(driver_version)"
	if [[ ! -f "$PLIST_DST" ]]; then
		verdict="未启用"
		advice="aibox cu install"
	elif [[ -f "$DISABLED_MARK" ]]; then
		verdict="已急停"
		advice="aibox cu on"
	elif ! agent_loaded; then
		verdict="异常 —— 网关已安装但未加载"
		advice="aibox cu restart"
	elif ! listening; then
		verdict="网关在运行,但还没开始监听(容器网络未就绪,或看日志)"
		advice="aibox cu doctor"
	elif [[ "$have" != "$CUA_VERSION" ]]; then
		verdict="异常 —— CuaDriver 版本 ${have:-缺失},需要 $CUA_VERSION"
		advice="aibox cu update"
	else
		verdict="正常"
	fi
	echo "== Mac 应用控制(computer use) =="
	field "总体状态  " "$verdict"
	field "CuaDriver " "${have:-未安装}$( [[ -z "$have" ]] || printf '(%s)' "$(tilde "$APP")")"
	pid="$(agent_pid)"
	if agent_loaded; then
		field "网关      " "运行中${pid:+(PID $pid)},端点 $(endpoint_host):$PORT"
	else
		field "网关      " "未运行"
	fi
	n="$(granted_count)"
	field "总是允许  " "${n:-0} 个应用(aibox cu apps 查看)"
	field "日志      " "$(tilde "$LOG_DIR")/gateway.log、audit.log"
	[[ -z "$advice" ]] || { echo; echo "  下一步: $advice"; }
}

do_doctor() {
	local rd out
	rd="$(run_dir)"
	echo "== Mac 应用控制诊断 =="
	if python_ok; then ok "/usr/bin/python3 可用($("$PY" -V 2>&1))"; else bad "缺少命令行工具自带的 python3:xcode-select --install"; fi
	if [[ -d "$APP" ]]; then
		if app_trusted "$APP"; then ok "CuaDriver $(driver_version) 签名正确(Team ID $CUA_TEAM)"
		else bad "$APP 签名校验失败或 Team ID 不对:重新运行 aibox cu install"; fi
		[[ "$(driver_version)" == "$CUA_VERSION" ]] || warn "版本 $(driver_version) 与 aibox 锁定的 $CUA_VERSION 不一致:aibox cu update"
		out="$("$DRIVER" telemetry status 2>&1 | head -n 1 || true)"
		[[ "$out" == *disabled* ]] && ok "遥测已关闭" || warn "遥测状态:${out:-未知}"
	else
		bad "未安装 CuaDriver:aibox cu install"
	fi
	if [[ -S "$rd/cua.sock" ]] && "$DRIVER" status --socket "$rd/cua.sock" --pid-file "$rd/cua.pid" >/dev/null 2>&1; then
		ok "网关专用的 CuaDriver 实例在运行(bounded 模式)"
		out="$("$DRIVER" call check_permissions '{}' --socket "$rd/cua.sock" 2>&1 || true)"
		if [[ "$out" == *'"accessibility": true'* && "$out" == *'"screen_recording": true'* ]]; then
			ok "辅助功能、屏幕录制权限正常"
		else
			bad "权限不完整:重新运行 aibox cu install 走一遍授权"
		fi
	else
		info "网关专用的 CuaDriver 实例没在运行(第一个容器连上时才启动),跳过权限检查"
	fi
	if [[ -f "$PLIST_DST" ]]; then ok "LaunchAgent 已安装:$(tilde "$PLIST_DST")"; else bad "LaunchAgent 未安装:aibox cu install"; fi
	if [[ -f "$DISABLED_MARK" ]]; then warn "处于急停状态:aibox cu on 恢复"
	elif agent_loaded; then ok "网关在运行(PID $(agent_pid))"
	else bad "网关没有运行:aibox cu restart"; fi
	if listening; then ok "端点 $(endpoint_host):$PORT 可连接"
	else bad "端点 $(endpoint_host):$PORT 连不上(没有容器在运行时容器网络的网卡可能不存在,先启动一个容器再看)"; fi
	if [[ -s "$CLIENT_DIR/token" ]]; then ok "token 存在($(tilde "$CLIENT_DIR/token"))"; else bad "缺少 token:aibox cu install"; fi
	if grep -q '"aibox-mac-mcp"' "$STATE_DIR/claude/.claude.json" 2>/dev/null; then ok "Claude Code 已注册 mac 服务"; else warn "Claude Code 未注册 mac 服务:aibox cu install"; fi
	if grep -q '>>> aibox cu >>>' "$STATE_DIR/codex/config.toml" 2>/dev/null; then ok "Codex 已注册 mac 服务"; else warn "Codex 未注册 mac 服务:aibox cu install"; fi
	if [[ -s "$LOG_DIR/gateway.log" ]]; then
		echo
		echo "  网关日志(末尾 5 行):"
		tail -n 5 "$LOG_DIR/gateway.log" | sed 's/^/    /'
	fi
	echo
	info "在容器里验证连通:aibox exec aibox-mac-mcp --check(长期容器)"
}

action="${1:-status}"
case "$action" in
	install|update) do_install ;;
	restart)        do_restart ;;
	status)         do_status ;;
	doctor)         do_doctor ;;
	off)            do_off ;;
	on)             do_on ;;
	uninstall)      do_uninstall ;;
	apps|allow|revoke)
		python_ok || { echo "需要命令行工具自带的 /usr/bin/python3:xcode-select --install" >&2; exit 1; }
		shift
		AIBOX_CU_STATE="$CU_DIR" exec "$PY" "$GATEWAY" "$action" "$@"
		;;
	*)
		echo "用法: aibox cu [install|status|doctor|apps|allow <应用>|revoke <应用>|off|on|update|restart|uninstall]" >&2
		exit 2 ;;
esac
