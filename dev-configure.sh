#!/bin/bash
# Refresh machine-wide settings before opening a persistent dev login session.
# This command runs as root with only the resolved proxy and timezone settings.
set -euo pipefail
umask 077

if [[ "$(id -u)" -ne 0 ]]; then
    echo "aibox dev configuration must run as root" >&2
    exit 1
fi

# container machine can admit a process while PID 1 is still creating its
# manager socket. Keep this helper safe when invoked independently of ai-box.
systemd_attempt=0
while (( systemd_attempt < 30 )); do
    if systemctl show --property=SystemState --value >/dev/null 2>&1; then
        break
    fi
    systemd_attempt=$((systemd_attempt + 1))
    sleep 1
done
if (( systemd_attempt == 30 )); then
    echo "aibox dev systemd did not become ready within 30 seconds" >&2
    exit 1
fi
unset systemd_attempt

system_tz="${AIBOX_TZ:-UTC}"
if [[ ! "$system_tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] \
   || [[ ! -e "/usr/share/zoneinfo/$system_tz" ]]; then
    echo "invalid or unavailable aibox dev timezone: $system_tz" >&2
    exit 1
fi
ln -snf "/usr/share/zoneinfo/$system_tz" /etc/localtime
printf '%s\n' "$system_tz" > /etc/timezone
unset system_tz

if [[ -z "${AIBOX_PROXY:-}" ]]; then
    systemctl stop aibox-dev-proxy.service >/dev/null 2>&1 || true
    rm -f /run/aibox/dev-proxy-url
    exit 0
fi
if ! command -v gost >/dev/null 2>&1; then
    echo "AIBOX_PROXY is configured, but gost is not installed in the dev image" >&2
    echo "rebuild after placing the Linux/arm64 gost binary in third_party/gost" >&2
    exit 1
fi

mkdir -p /run/aibox
chmod 0711 /run/aibox
printf '%s\n' "$AIBOX_PROXY" > /run/aibox/dev-proxy-url
chown aibox-gost:aibox-gost /run/aibox/dev-proxy-url
chmod 0400 /run/aibox/dev-proxy-url
systemctl restart aibox-dev-proxy.service
sleep 1
if ! systemctl is-active --quiet aibox-dev-proxy.service; then
    echo "aibox dev proxy service failed to start" >&2
    exit 1
fi
