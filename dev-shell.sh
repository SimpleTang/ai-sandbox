#!/bin/bash
# Login-session wrapper for the persistent development machine. Configuration
# is supplied by the host launcher through container machine run --env-file.
set -euo pipefail

# AIBOX_ENV_VARS may intentionally replace PATH. Keep that value for the final
# process, but use a trusted path while this wrapper validates and applies config.
AIBOX_DEV_FINAL_PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

aibox_custom_has() {
    case ",${AIBOX_DEV_CUSTOM_NAMES:-}," in
        *",$1,"*) return 0 ;;
        *)         return 1 ;;
    esac
}
aibox_export_default() {
    if ! aibox_custom_has "$1"; then
        export "$1=$2"
    fi
}

if [[ -n "${AIBOX_TZ:-}" ]] && ! aibox_custom_has TZ; then
    export TZ="$AIBOX_TZ"
fi
if [[ -n "${AIBOX_LANG:-}" ]] \
   && { ! aibox_custom_has LANG || ! aibox_custom_has LANGUAGE || ! aibox_custom_has LC_ALL; }; then
    want_norm="$(printf '%s' "$AIBOX_LANG" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"
    if locale -a 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/' | grep -qx "$want_norm"; then
        aibox_export_default LANG "$AIBOX_LANG"
        aibox_export_default LANGUAGE "${AIBOX_LANG%%.*}"
        aibox_export_default LC_ALL "$AIBOX_LANG"
    else
        echo "warning: locale '$AIBOX_LANG' is unavailable; using C.UTF-8" >&2
        aibox_export_default LANG C.UTF-8
        aibox_export_default LC_ALL C.UTF-8
    fi
    unset want_norm
fi

if [[ -n "${AIBOX_PROXY:-}" ]]; then
    aibox_export_default HTTP_PROXY "http://127.0.0.1:8080"
    aibox_export_default HTTPS_PROXY "http://127.0.0.1:8080"
    aibox_export_default http_proxy "http://127.0.0.1:8080"
    aibox_export_default https_proxy "http://127.0.0.1:8080"
    aibox_export_default ALL_PROXY "http://127.0.0.1:8080"
    aibox_export_default all_proxy "http://127.0.0.1:8080"
    aibox_export_default NO_PROXY "localhost,127.0.0.1,::1"
    aibox_export_default no_proxy "localhost,127.0.0.1,::1"
fi
unset AIBOX_PROXY AIBOX_DEV_CUSTOM_NAMES
unset -f aibox_custom_has aibox_export_default
export PATH="$AIBOX_DEV_FINAL_PATH"
unset AIBOX_DEV_FINAL_PATH

if [[ $# -gt 0 ]]; then
    # Exec sessions do not start a login shell, so load the machine profile here.
    # shellcheck disable=SC1091
    [[ ! -r /etc/profile.d/aibox-dev.sh ]] || source /etc/profile.d/aibox-dev.sh
    exec "$@"
fi

exec /bin/bash -l
