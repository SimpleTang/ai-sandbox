#!/bin/bash
set -euo pipefail

IFS= read -r AIBOX_PROXY < /run/aibox/dev-proxy-url
case "$AIBOX_PROXY" in
    *\?*) gost_query_sep="&" ;;
    *)    gost_query_sep="?" ;;
esac
exec /usr/local/bin/gost -L http://127.0.0.1:8080 \
    -F "${AIBOX_PROXY}${gost_query_sep}retry=3&timeout=8s&so_keepalive=true"
