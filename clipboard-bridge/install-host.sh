#!/bin/bash
# install-host.sh —— 剪贴板图片桥接的「宿主机侧」安装器(macOS)
#
# 一般不直接调用,走 ai-box 的子命令:
#   aibox clip install     安装并立即启动(开机自启)
#   aibox clip uninstall   停止并彻底移除
#   aibox clip status      查看运行状态
#   aibox clip restart     重启监听(改过 AppleScript 后用)
#
# 沙箱侧那半截(xclip 垫片)已经烧进镜像,aibox build / aibox dev build 之后开箱即用,
# 这里只负责 macOS 上装不进镜像的常驻监听。原理见同目录 README.md。
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "错误: 这个脚本要在 macOS 宿主机上跑,不是在沙箱里。" >&2
	exit 1
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.local.clipbridge"
PLIST_SRC="$SCRIPT_DIR/com.local.clipbridge.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
BRIDGE_DIR="$HOME/.clipboard-bridge"
# launchd 配置里写的是监听脚本的绝对路径。程序目录可能随升级整体替换(例如 brew 每个版本
# 一个目录),所以安装时把脚本复制到这里,launchd 指向这份副本;升级后 aibox clip restart 刷新。
WATCHER_HOME="$HOME/.aibox/clipboard"
DOMAIN="gui/$(id -u)"

# 监听实现:默认 JXA。它用 NSPasteboard.changeCount(O(1) 整数)检测剪贴板变化;
# AppleScript 版只能用 clipboard info,而后者为了报告字节数会把图真的渲染一遍 ——
# 实测每轮约 1.5 秒,且只要剪贴板里有图就持续占 CPU。AppleScript 版保留作退路:
#   CLIPBRIDGE_IMPL=applescript aibox clip install
case "${CLIPBRIDGE_IMPL:-jxa}" in
	jxa)
		WATCHER="$SCRIPT_DIR/clipbridge.js"
		WATCHER_LANG="JavaScript"
		;;
	applescript)
		WATCHER="$SCRIPT_DIR/clipbridge.applescript"
		WATCHER_LANG="AppleScript"
		;;
	*)
		echo "错误: CLIPBRIDGE_IMPL 只能是 jxa 或 applescript" >&2
		exit 1
		;;
esac

do_install() {
	[[ -f "$WATCHER" ]]   || { echo "错误: 找不到 $WATCHER" >&2; exit 1; }
	[[ -f "$PLIST_SRC" ]] || { echo "错误: 找不到 $PLIST_SRC" >&2; exit 1; }

	# 目录权限 0755 而非 0700:一次性容器(aibox)里的运行用户是 node(UID 1000),
	# 与宿主机用户 UID 不同,0700 会读不到挂进去的桥接目录。目录里只会出现你主动
	# 复制的图片 —— 监听刻意不镜像剪贴板文本 —— 因此这个放宽是可接受的。
	mkdir -p "$BRIDGE_DIR" "$HOME/Library/LaunchAgents"
	chmod 0755 "$BRIDGE_DIR"

	# 装/换实现时清掉旧的 stderr:上一个实现留下的噪音会被 aibox clip doctor
	# 当成「错误日志」原样打出来,查问题时极具误导性。
	: > "$BRIDGE_DIR/clipbridge.err" 2>/dev/null || true

	# 已经装过就先卸掉,保证幂等
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

	# bootout 是异步的:launchd 可能还没真正卸载完就返回,此时紧接着 bootstrap 会以
	# "Bootstrap failed: 5: Input/output error" 失败,而且失败后 job 是卸载状态 ——
	# 监听会直接停掉。必须等它真的消失。
	unload_wait=0
	while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; do
		unload_wait=$((unload_wait + 1))
		if (( unload_wait > 50 )); then
			echo "错误: 旧的 $LABEL 在 5 秒内没有卸载完成。" >&2
			echo "      试试 launchctl bootout $DOMAIN/$LABEL 后重跑。" >&2
			exit 1
		fi
		sleep 0.1
	done

	mkdir -p "$WATCHER_HOME"
	cp "$WATCHER" "$WATCHER_HOME/$(basename "$WATCHER")"
	WATCHER="$WATCHER_HOME/$(basename "$WATCHER")"

	sed -e "s|__SCRIPT__|$WATCHER|g" -e "s|__LANG__|$WATCHER_LANG|g" \
		-e "s|__LOGDIR__|$BRIDGE_DIR|g" \
		"$PLIST_SRC" > "$PLIST_DST"

	# 渲染出来的东西先自检,免得把一个坏 plist 交给 launchd 再去猜错误码
	if ! /usr/bin/plutil -lint "$PLIST_DST" >/dev/null; then
		echo "错误: 生成的 $PLIST_DST 不是合法的 plist。" >&2
		exit 1
	fi

	bootstrap_try=0
	until launchctl bootstrap "$DOMAIN" "$PLIST_DST" 2>"$BRIDGE_DIR/.bootstrap.err"; do
		bootstrap_try=$((bootstrap_try + 1))
		if (( bootstrap_try >= 3 )); then
			echo "错误: 无法加载 $LABEL" >&2
			sed 's/^/      /' "$BRIDGE_DIR/.bootstrap.err" >&2
			echo "      排查: launchctl print $DOMAIN/$LABEL" >&2
			rm -f "$BRIDGE_DIR/.bootstrap.err"
			exit 1
		fi
		sleep 0.5
	done
	rm -f "$BRIDGE_DIR/.bootstrap.err"
	launchctl enable "$DOMAIN/$LABEL"

	echo "已安装并启动: $LABEL"
	echo "  监听脚本: $WATCHER ($WATCHER_LANG)"
	echo "  桥接目录: $BRIDGE_DIR"
	echo
	echo "接下来:在 macOS 上复制一张图,然后 aibox clip status 自检。"
	echo "沙箱里按 Ctrl+V 粘贴(不是 ⌘V —— ⌘V 会被终端截走当文本粘贴)。"
}

# 重启 = 重新渲染 plist + 重新 bootstrap。
# 不能只用 launchctl kickstart:它重启的是「已加载的 job 定义」,监听脚本换了路径
# 或换了解释器(AppleScript -> JXA)都不会生效 —— 会安静地继续跑旧实现。
do_restart() {
	if [[ ! -f "$PLIST_DST" ]]; then
		echo "尚未安装,先跑 aibox clip install" >&2
		exit 1
	fi
	do_install
}

do_uninstall() {
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	rm -f "$PLIST_DST"
	rm -rf "$BRIDGE_DIR" "$WATCHER_HOME"
	echo "已停止并移除: $LABEL"
	echo "(沙箱侧的 xclip 垫片在镜像里,不受影响;桥接目录一消失它就会安静地报告没有图)"
}

# 字段宽度与 aibox status / aibox dev status 保持一致(标签占 11 个显示列)
clip_field() { printf '  %s : %s\n' "$1" "$2"; }

human_size() {
	local bytes="$1"
	if (( bytes >= 1048576 )); then
		printf '%d.%d MB' $((bytes / 1048576)) $(( bytes % 1048576 * 10 / 1048576 ))
	elif (( bytes >= 1024 )); then
		printf '%d KB' $((bytes / 1024))
	else
		printf '%d 字节' "$bytes"
	fi
}

# 把 /Users/xxx 缩成 ~,长路径在终端里更好认。
# 替换串里不能直接写 ~(会被当成波浪号展开),用变量绕开。
tilde() {
	local mark='~'
	printf '%s' "${1/#$HOME/$mark}"
}

do_status() {
	local loaded=0 pid="" lang="" script="" impl="未知"
	local heartbeat_age=-1 image_bytes=0 verdict advice=""

	# --- 采集 ---
	if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
		loaded=1
		pid="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
			| awk -F'= *' '/^[[:space:]]*pid =/ { print $2; exit }')"
	fi

	if [[ -f "$PLIST_DST" ]]; then
		# 读已安装的那份,而不是仓库模板 —— 两者可能不一致,这正是要暴露的信息
		lang="$(/usr/bin/plutil -extract ProgramArguments.2 raw -o - "$PLIST_DST" 2>/dev/null)"
		script="$(/usr/bin/plutil -extract ProgramArguments.3 raw -o - "$PLIST_DST" 2>/dev/null)"
		case "$lang" in
			JavaScript) impl="JXA（changeCount 检测，推荐）" ;;
			AppleScript) impl="AppleScript（clipboard info 检测，较慢）" ;;
			*) impl="未知（${lang}）" ;;
		esac
	fi

	if [[ -f "$BRIDGE_DIR/alive" ]]; then
		heartbeat_age=$(( $(date +%s) - $(stat -f %m "$BRIDGE_DIR/alive") ))
	fi

	if [[ -s "$BRIDGE_DIR/clipboard.png" && -f "$BRIDGE_DIR/targets" ]]; then
		image_bytes=$(wc -c < "$BRIDGE_DIR/clipboard.png" | tr -d ' ')
	fi

	# --- 判定 ---
	if (( loaded == 0 )) && [[ ! -f "$PLIST_DST" ]]; then
		verdict="未启用"
		advice="aibox clip install"
	elif (( loaded == 0 )); then
		verdict="异常 —— 已安装但未加载"
		advice="aibox clip restart"
	elif [[ ! -f "$PLIST_DST" ]]; then
		# job 挂着但 plist 被删了:下次登录不会再自启,而且改配置已无处可改
		verdict="异常 —— 已加载但 plist 缺失"
		advice="aibox clip install"
	elif (( heartbeat_age < 0 )); then
		verdict="异常 —— 没有心跳"
		advice="aibox clip doctor"
	elif (( heartbeat_age > 30 )); then
		verdict="异常 —— 心跳已停 ${heartbeat_age} 秒"
		advice="aibox clip restart"
	elif (( image_bytes > 0 )); then
		verdict="正常，当前有图可粘"
	else
		verdict="正常，当前剪贴板无图"
	fi

	# --- 输出 ---
	echo "== 剪贴板图片桥接 =="
	clip_field "总体状态  " "$verdict"

	if (( loaded )); then
		# 花括号不能省:macOS 自带的是 bash 3.2,变量名解析不认多字节字符,
		# 紧跟其后的全角「）」会被当成标识符的一部分,报 "pid?: unbound variable"。
		if [[ -n "$pid" ]]; then
			clip_field "监听进程  " "运行中（PID ${pid}）"
		else
			clip_field "监听进程  " "运行中"
		fi
	elif [[ -f "$PLIST_DST" ]]; then
		clip_field "监听进程  " "未加载"
	else
		clip_field "监听进程  " "未安装"
	fi

	if [[ -f "$PLIST_DST" ]]; then
		clip_field "实现      " "$impl"
		clip_field "监听脚本  " "$(tilde "${script:-未知}")"
	fi

	if (( heartbeat_age >= 0 )); then
		clip_field "心跳      " "${heartbeat_age} 秒前（正常应 < 10，超时阈值 30）"
	else
		clip_field "心跳      " "无"
	fi

	clip_field "桥接目录  " "$(tilde "$BRIDGE_DIR")$( [[ -d "$BRIDGE_DIR" ]] || printf '（不存在）' )"

	if (( image_bytes > 0 )); then
		clip_field "当前剪贴板" "有图 $(human_size "$image_bytes")，$(stat -f %Sm -t '%H:%M:%S' \
			"$BRIDGE_DIR/clipboard.png") 捕获 —— 沙箱里按 Ctrl+V"
	else
		clip_field "当前剪贴板" "无图（在 macOS 上复制一张图再看）"
	fi

	if [[ -s "$BRIDGE_DIR/clipbridge.log" ]]; then
		echo
		echo "  最近日志:"
		tail -n 3 "$BRIDGE_DIR/clipbridge.log" | sed 's/^/    /'
	fi

	if [[ -s "$BRIDGE_DIR/clipbridge.err" ]]; then
		echo
		echo "  监听 stderr（末尾 3 行）:"
		tail -n 3 "$BRIDGE_DIR/clipbridge.err" | sed 's/^/    /'
	fi

	if [[ -n "$advice" ]]; then
		echo
		echo "  下一步: $advice"
	fi
}

case "${1:-status}" in
	install)   do_install ;;
	uninstall) do_uninstall ;;
	status)    do_status ;;
	restart)   do_restart ;;
	*)
		echo "用法: $0 {install|uninstall|status|restart}" >&2
		exit 1 ;;
esac
