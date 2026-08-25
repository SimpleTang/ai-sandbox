#!/bin/sh
# Proxy-mode egress firewall. Only loopback and the dedicated gost UID may open
# outbound connections; every other IPv4/IPv6 path fails closed.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "aibox network lockdown must run as root" >&2
    exit 1
fi

GOST_UID="${1:-}"
case "$GOST_UID" in
    ''|*[!0-9]*)
        echo "aibox network lockdown requires a numeric gost UID" >&2
        exit 1
        ;;
esac

apply_rules() {
    firewall_cmd="$1"
    command -v "$firewall_cmd" >/dev/null 2>&1 || {
        echo "missing firewall command: $firewall_cmd" >&2
        exit 1
    }

    # Build the private chain first and link it into OUTPUT only after the
    # terminal reject exists. Existing runtime firewall chains stay untouched.
    "$firewall_cmd" -w -N AIBOX_OUTPUT
    "$firewall_cmd" -w -A AIBOX_OUTPUT -o lo -j ACCEPT
    "$firewall_cmd" -w -A AIBOX_OUTPUT -m owner --uid-owner "$GOST_UID" -j ACCEPT
    "$firewall_cmd" -w -A AIBOX_OUTPUT -j REJECT
    "$firewall_cmd" -w -I OUTPUT 1 -j AIBOX_OUTPUT
    "$firewall_cmd" -w -C OUTPUT -j AIBOX_OUTPUT
    "$firewall_cmd" -w -C AIBOX_OUTPUT -j REJECT
}

apply_rules iptables
apply_rules ip6tables
