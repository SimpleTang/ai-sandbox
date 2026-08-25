#!/usr/bin/env bash
# Import user-controlled variables only after privilege drop, then exec the
# requested command. The same path is used by initial launch and aibox enter.
set -euo pipefail

# container exec starts from image/container metadata rather than PID 1's
# mutated environment, so reconstruct runtime proxy and regional variables.
if [[ -n "${AIBOX_PROXY:-}" ]]; then
    export HTTP_PROXY="http://127.0.0.1:${LOCAL_HTTP_PORT:-8080}"
    export HTTPS_PROXY="$HTTP_PROXY"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTP_PROXY"
    export ALL_PROXY="$HTTP_PROXY"
    export all_proxy="$HTTP_PROXY"
    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="$NO_PROXY"
fi
if [[ -n "${AIBOX_TZ:-}" ]]; then
    export TZ="$AIBOX_TZ"
fi
if [[ -n "${AIBOX_LANG:-}" ]]; then
    want_norm="$(printf '%s' "$AIBOX_LANG" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"
    if locale -a 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/' | grep -qx "$want_norm"; then
        export LANG="$AIBOX_LANG" LANGUAGE="${AIBOX_LANG%%.*}" LC_ALL="$AIBOX_LANG"
    fi
    unset want_norm
fi

USER_ENV_FILE="${AIBOX_USER_ENV_FILE:-/run/aibox/user-env-runtime}"
unset AIBOX_USER_ENV_FILE
if [[ -r "$USER_ENV_FILE" ]]; then
    while IFS= read -r custom_env_entry || [[ -n "$custom_env_entry" ]]; do
        custom_env_name="${custom_env_entry%%=*}"
        if [[ "$custom_env_entry" != *=* \
           || ! "$custom_env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
           || "$custom_env_name" == AIBOX_* ]]; then
            echo "invalid aibox user environment file" >&2
            exit 1
        fi
        export "$custom_env_entry"
    done < "$USER_ENV_FILE"
    unset custom_env_entry custom_env_name
fi

exec "$@"
