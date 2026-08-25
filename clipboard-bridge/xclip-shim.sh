#!/bin/bash
# xclip 垫片 —— 镜像内安装为 /usr/local/bin/xclip
#
# 为什么需要它:
#   沙箱里没有 X11/Wayland,更读不到宿主机 macOS 的剪贴板,所以 Claude Code 的
#   Ctrl+V 贴图功能直接失效。而 Claude Code 在 Linux 下贴图,实际就是 sh -c 执行:
#
#     xclip -selection clipboard -t TARGETS   -o | grep -E "image/(png|jpeg|jpg|gif|webp|bmp)"
#     xclip -selection clipboard -t image/png -o > <临时文件>
#
#   这两步中间没有任何 DISPLAY 检查(DISPLAY 只在「往剪贴板写」那条路径上才判断)。
#   所以只要 PATH 里有个叫 xclip 的东西能正确响应这两条命令,Ctrl+V 就能用 ——
#   它不必是真的 xclip,也不需要 X server。
#
# 数据从哪来:
#   宿主机上常驻的 clipbridge.js 把剪贴板里的图片写成 <桥接目录>/clipboard.png。
#   桥接目录在两种运行模式下位置不同,由 ai-box 通过 CLIP_BRIDGE_DIR 传入。
#
# 环境变量:
#   CLIP_BRIDGE_DIR      桥接目录(ai-box 注入;缺省时自行兜底)
#   CLIP_BRIDGE_STALE    心跳超时秒数,默认 30
#   CLIP_BRIDGE_ONESHOT  1(默认)= 同一张图只交付一次;0 = 允许重复粘贴
#   CLIP_BRIDGE_STATE    消费标记的存放目录,默认 ${TMPDIR:-/tmp}/clipboard-bridge
set -u

# ---- 桥接目录定位 ----
# 1) CLIP_BRIDGE_DIR:ai-box 启动时注入,两种模式下都是准确值,优先采信。
# 2) /run/aibox/clipboard-bridge:一次性容器(aibox)的固定挂载点。宿主 Home 未整体
#    挂入容器,ai-box 单独把 ~/.clipboard-bridge 只读挂到这里。
# 3) /Users/*/.clipboard-bridge:持久开发机(aibox dev)用 --home-mount rw 挂了宿主
#    Home,路径与 macOS 侧完全一致。这条兜底让绕过 ai-box 直接 container machine run
#    进来的会话也能用。
resolve_bridge() {
	if [ -n "${CLIP_BRIDGE_DIR:-}" ]; then
		printf '%s' "$CLIP_BRIDGE_DIR"
		return
	fi
	if [ -d /run/aibox/clipboard-bridge ]; then
		printf '%s' /run/aibox/clipboard-bridge
		return
	fi
	for d in /Users/*/.clipboard-bridge; do
		[ -d "$d" ] && { printf '%s' "$d"; return; }
	done
	printf '%s' /run/aibox/clipboard-bridge   # 不存在也无妨,后续检查会失败并优雅退出
}

BRIDGE="$(resolve_bridge)"
PNG="$BRIDGE/clipboard.png"
TGT="$BRIDGE/targets"
ALIVE="$BRIDGE/alive"
STALE_SECS="${CLIP_BRIDGE_STALE:-30}"
ONESHOT="${CLIP_BRIDGE_ONESHOT:-1}"
# 消费标记不能写进桥接目录:一次性容器里它是只读挂载。放容器本地,天然按容器隔离。
STATE_DIR="${CLIP_BRIDGE_STATE:-${TMPDIR:-/tmp}/clipboard-bridge}"
CONSUMED="$STATE_DIR/consumed"

# 万一哪天真装了 xclip 并且有 X11,把活儿还给它
if [ -n "${DISPLAY:-}" ] && [ -x /usr/bin/xclip ]; then
	exec /usr/bin/xclip "$@"
fi

target=""
mode="out"
while [ $# -gt 0 ]; do
	case "$1" in
		-t|-target)      target="${2:-}"; shift 2 ;;
		-o|-out|-output) mode="out"; shift ;;
		-i|-in|-input)   mode="in";  shift ;;
		-selection|-sel) shift 2 ;;
		-d|-display)     shift 2 ;;
		*)               shift ;;
	esac
done

# GNU 与 BSD 的 stat 参数不通用,而且 GNU 的 -f 是「显示文件系统信息」——
# 它会「成功」并吐出无关内容,不会触发 || 兜底,所以必须校验是不是纯数字。
file_mtime() {
	value=$(stat -c %Y "$1" 2>/dev/null) || value=""
	case "$value" in
		''|*[!0-9]*) value=$(stat -f %m "$1" 2>/dev/null) || value="" ;;
	esac
	case "$value" in
		''|*[!0-9]*) value=0 ;;
	esac
	printf '%s' "$value"
}

# 指纹:大小 + mtime。每次捕获都是原子重写,mtime 必变 —— 即便重新复制同一张图,
# 也会得到新指纹,因此「再复制一次」总能重新粘贴。
fingerprint() {
	printf '%s:%s' "$(wc -c < "$PNG" 2>/dev/null || echo 0)" "$(file_mtime "$PNG")"
}

already_consumed() {
	[ "$ONESHOT" = "1" ] || return 1
	[ -f "$CONSUMED" ] || return 1
	[ "$(cat "$CONSUMED" 2>/dev/null)" = "$(fingerprint)" ]
}

mark_consumed() {
	[ "$ONESHOT" = "1" ] || return 0
	mkdir -p "$STATE_DIR" 2>/dev/null || return 0
	fingerprint > "$CONSUMED" 2>/dev/null || true
}

has_image() {
	[ -s "$PNG" ] || return 1
	grep -q 'image/png' "$TGT" 2>/dev/null || return 1
	# 宿主机上的监听进程要是死了,就别再吐一张陈年旧图出来
	[ -f "$ALIVE" ] || return 1
	[ $(( $(date +%s) - $(file_mtime "$ALIVE") )) -le "$STALE_SECS" ] || return 1
	# 已经交付过的同一张图不再重复交付,否则连按几次 Ctrl+V 会叠出多张一模一样的附件
	! already_consumed
}

# 写方向(-i):本桥接是只读的,安静吃掉输入即可,免得调用方报错
if [ "$mode" = "in" ]; then
	cat >/dev/null
	exit 0
fi

case "$target" in
	TARGETS)
		has_image && printf 'image/png\n'
		printf 'TARGETS\n'
		exit 0
		;;
	image/png)
		has_image || exit 1
		cat "$PNG" || exit 1
		mark_consumed
		exit 0
		;;
	*)
		# text/plain 等一律不响应:文本走终端自带的粘贴就够了,
		# 而且宿主机监听刻意不镜像剪贴板文本(隐私)。
		exit 1
		;;
esac
