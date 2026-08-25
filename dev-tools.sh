#!/bin/bash
# Manage AI CLIs installed on the persistent machine's writable system disk.
set -euo pipefail

action="${1:-}"
target="${2:-all}"

case "$target" in
    all|claude|codex) ;;
    *)
        echo "aibox dev tools target must be all, claude, or codex" >&2
        exit 2
        ;;
esac

show_versions() {
    local npm_root package_json package_version
    npm_root="$(npm root -g)"
    if [[ "$target" == "all" || "$target" == "claude" ]]; then
        package_json="$npm_root/@anthropic-ai/claude-code/package.json"
        if [[ -r "$package_json" ]]; then
            package_version="$(node -e 'console.log(require(process.argv[1]).version)' "$package_json")"
            echo "claude-code: $package_version"
        else
            echo "claude-code: not installed"
        fi
    fi
    if [[ "$target" == "all" || "$target" == "codex" ]]; then
        package_json="$npm_root/@openai/codex/package.json"
        if [[ -r "$package_json" ]]; then
            package_version="$(node -e 'console.log(require(process.argv[1]).version)' "$package_json")"
            echo "codex:       $package_version"
        else
            echo "codex:       not installed"
        fi
    fi
}

case "$action" in
    version)
        show_versions
        ;;
    update)
        if [[ "$(id -u)" -ne 0 ]]; then
            echo "aibox dev update must run as root" >&2
            exit 1
        fi

        if [[ -s /run/aibox/dev-proxy-url ]]; then
            export HTTP_PROXY="http://127.0.0.1:8080"
            export HTTPS_PROXY="$HTTP_PROXY"
            export http_proxy="$HTTP_PROXY"
            export https_proxy="$HTTP_PROXY"
            export ALL_PROXY="$HTTP_PROXY"
            export all_proxy="$HTTP_PROXY"
            export NO_PROXY="localhost,127.0.0.1,::1"
            export no_proxy="$NO_PROXY"
        fi

        packages=()
        [[ "$target" == "all" || "$target" == "claude" ]] \
            && packages+=("@anthropic-ai/claude-code@latest")
        [[ "$target" == "all" || "$target" == "codex" ]] \
            && packages+=("@openai/codex@latest")
        npm install -g --registry=https://registry.npmmirror.com "${packages[@]}"
        show_versions
        ;;
    *)
        echo "usage: aibox-dev-tools <update|version> [all|claude|codex]" >&2
        exit 2
        ;;
esac
