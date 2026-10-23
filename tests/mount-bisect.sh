#!/usr/bin/env bash
# mount-bisect.sh —— 定位「aibox 挂载 ~/ai-sandbox 时 /workspace/ai-sandbox 为空」的触发因素。
# 在宿主机(macOS)运行:  bash ~/ai-sandbox/tests/mount-bisect.sh
# 每个用例在上一个的基础上多加一个 aibox 会传的因素,第一个 EMPTY 的用例就是触发点。
# 兼容 macOS 自带 Bash 3.2。
set -u

IMAGE="ai-sandbox:latest"
SB="$HOME/ai-sandbox"
TGT="/workspace/ai-sandbox"

# 结果打唯一标记,避免 entrypoint 横幅 / gost 日志干扰判读
CHECK="if [ -n \"\$(ls -A $TGT 2>/dev/null)\" ]; then echo BISECT_RESULT=OK; else echo BISECT_RESULT=EMPTY; fi"

# 代理值与真实 aibox 同源(aibox.conf),用于最后的环境变量用例
AIBOX_PROXY=""; AIBOX_TZ=""; AIBOX_LANG=""
# shellcheck disable=SC1090
[ -f "$SB/aibox.conf" ] && . "$SB/aibox.conf"
export AIBOX_PROXY

i=0
run_case() {
    desc="$1"; shift
    i=$((i+1))
    out="$(container run --rm "$@" "$IMAGE" sh -c "$CHECK" 2>&1)"
    verdict="$(printf '%s\n' "$out" | sed -n 's/.*BISECT_RESULT=//p' | tail -1)"
    [ -z "$verdict" ] && verdict="启动失败"
    printf '  [%d] %-44s %s\n' "$i" "$desc" "$verdict"
    if [ "$verdict" != "OK" ]; then
        printf '%s\n' "$out" | sed 's/^/      | /'
    fi
}

echo "== aibox 挂载二分测试(镜像 $IMAGE,项目 $SB)=="

run_case "仅项目挂载 -> $TGT" \
    -v "$SB:$TGT"

run_case "+ 工作目录 -w" \
    -v "$SB:$TGT" -w "$TGT"

run_case "+ creds/claude 嵌套挂载" \
    -v "$SB:$TGT" -w "$TGT" \
    -v "$SB/creds/claude:/home/node/.claude"

run_case "+ creds/codex" \
    -v "$SB:$TGT" -w "$TGT" \
    -v "$SB/creds/claude:/home/node/.claude" \
    -v "$SB/creds/codex:/home/node/.codex"

run_case "+ entrypoint.sh 单文件只读挂载" \
    -v "$SB:$TGT" -w "$TGT" \
    -v "$SB/creds/claude:/home/node/.claude" \
    -v "$SB/creds/codex:/home/node/.codex" \
    -v "$SB/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro"

run_case "+ --memory 8192M --name ai-ai-sandbox-*" \
    --memory 8192M --name "ai-ai-sandbox-b6$$" \
    -v "$SB:$TGT" -w "$TGT" \
    -v "$SB/creds/claude:/home/node/.claude" \
    -v "$SB/creds/codex:/home/node/.codex" \
    -v "$SB/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro"

run_case "+ AIBOX_* 环境变量(含真实代理)" \
    --memory 8192M --name "ai-ai-sandbox-b7$$" \
    -v "$SB:$TGT" -w "$TGT" \
    -v "$SB/creds/claude:/home/node/.claude" \
    -v "$SB/creds/codex:/home/node/.codex" \
    -v "$SB/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
    -e AIBOX_PROXY \
    -e "AIBOX_PROXY_SRC=aibox.conf" \
    -e "AIBOX_TZ=${AIBOX_TZ}" -e "AIBOX_TZ_SRC=bisect" \
    -e "AIBOX_LANG=${AIBOX_LANG}" -e "AIBOX_LANG_SRC=bisect" \
    -e "AIBOX_PROJECT=ai-sandbox" \
    -e "AIBOX_HOST_DIR=$SB" \
    -e "AIBOX_MOUNT=$TGT" \
    -e "AIBOX_CONTAINER=ai-ai-sandbox-b7$$"

echo "== 完成。第一个 EMPTY 的用例即触发因素;全 OK 则见脚本同目录说明 =="
