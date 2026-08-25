#!/bin/sh
# Trusted container-exec trampoline. Proxy containers drop every capability
# before opening the shell; direct containers retain their existing sudo model.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "aibox enter helper must start as root" >&2
    exit 1
fi

node_uid="$(id -u node)"
node_gid="$(id -g node)"

if [ -f /run/aibox/proxy-lockdown ]; then
    exec setpriv --reuid="$node_uid" --regid="$node_gid" --init-groups \
        --bounding-set=-all --no-new-privs -- \
        env HOME=/home/node USER=node LOGNAME=node \
        /usr/local/bin/aibox-user-exec bash
fi

exec setpriv --reuid="$node_uid" --regid="$node_gid" --init-groups -- \
    env HOME=/home/node USER=node LOGNAME=node \
    /usr/local/bin/aibox-user-exec bash
