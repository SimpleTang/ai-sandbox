#!/bin/bash
# aibox-img —— 列出宿主机 macOS 上最近的图片路径(沙箱内可直接读取这些文件)
#
# Ctrl+V 不方便时的兜底:
#   aibox-img        最新 1 张
#   aibox-img 5      最新 5 张
# 拿到路径丢给 Claude Code 即可。
#
# 注意两种模式可见范围不同:
#   aibox dev   宿主 Home 整个挂进来,桌面/下载目录都能翻到
#   aibox       只挂了项目目录 + 桥接目录,因此只能看到桥接目录里那张
set -u

candidates=""
[ -n "${CLIP_BRIDGE_DIR:-}" ] && candidates="$CLIP_BRIDGE_DIR"
[ -d /run/aibox/clipboard-bridge ] && candidates="$candidates /run/aibox/clipboard-bridge"
for h in /Users/*/; do
	[ -d "$h" ] || continue
	candidates="$candidates ${h}.clipboard-bridge ${h}Desktop ${h}Downloads ${h}Pictures/Screenshots"
done

# shellcheck disable=SC2086
[ -n "$candidates" ] && find $candidates -maxdepth 1 -type f \
	\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
	   -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.heic' \) \
	-printf '%T@ %p\n' 2>/dev/null \
	| sort -rn | head -n "${1:-1}" | cut -d' ' -f2-
