#!/bin/bash
# diagnose.sh —— 在 macOS 上诊断剪贴板桥接为什么没抓到图
# 走 aibox clip doctor 调用。必须在 macOS 上跑,不是在沙箱里。
#
# 关键点:它在「前台」重跑一遍监听做的事。如果前台能读到而后台常驻读不到,
# 那就是运行上下文/权限问题,而不是脚本逻辑问题。
set -u

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "错误: 这个脚本要在 macOS 宿主机上跑,不是在沙箱里。" >&2
	exit 1
fi

BRIDGE="$HOME/.clipboard-bridge"
LABEL="com.local.clipbridge"

echo "== 系统 =="
sw_vers 2>/dev/null | sed 's/^/  /'

echo
echo "== 常驻监听 =="
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
	launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null \
		| grep -E '^[[:space:]]*(state|pid|last exit code)' | sed 's/^/  /'
else
	echo "  未加载(跑 aibox clip install)"
fi

echo
echo "== 桥接目录 $BRIDGE =="
ls -l "$BRIDGE" 2>&1 | sed 's/^/  /'
if [[ -f "$BRIDGE/alive" ]]; then
	echo "  心跳距今 $(( $(date +%s) - $(stat -f %m "$BRIDGE/alive") )) 秒"
fi

echo
echo "== 前台自检:JXA 监听 =="
echo "  (若系统要授权,提示会当场弹出来 —— 后台常驻是弹不出来的)"
if [[ -f "$SCRIPT_DIR/clipbridge.js" ]]; then
	/usr/bin/osascript -l JavaScript "$SCRIPT_DIR/clipbridge.js" --selftest 2>&1 | sed 's/^/  /'
else
	echo "  找不到 $SCRIPT_DIR/clipbridge.js"
fi
echo
echo "  说明:"
echo "    抓取结果 ok:<字节数>  = 剪贴板里的图已成功落盘,桥接可用"
echo "    抓取结果 noimage      = 剪贴板里当下没有图片"
echo "    changeCount 20 次耗时 = 变化检测的成本,正常应是个位数毫秒"
echo "      (对比:AppleScript 的 clipboard info 单次就要约 1500 ms)"

echo
echo "== 监听错误日志(末尾 20 行) =="
if [[ -s "$BRIDGE/clipbridge.err" ]]; then
	tail -n 20 "$BRIDGE/clipbridge.err" | sed 's/^/  /'
else
	echo "  (空)"
fi
