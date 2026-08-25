#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n \
    "$ROOT/ai-box" \
    "$ROOT/entrypoint.sh" \
    "$ROOT/ai-box-completion.sh" \
    "$ROOT/network-lockdown.sh" \
    "$ROOT/user-exec.sh" \
    "$ROOT/enter-shell.sh" \
    "$ROOT/dev-profile.sh" \
    "$ROOT/dev-shell.sh" \
    "$ROOT/dev-configure.sh" \
    "$ROOT/dev-proxy-run.sh" \
    "$ROOT/dev-tools.sh" \
    "$ROOT/clipboard-bridge/install-host.sh" \
    "$ROOT/clipboard-bridge/xclip-shim.sh" \
    "$ROOT/clipboard-bridge/img.sh" \
    "$ROOT/clipboard-bridge/diagnose.sh"

# The JXA watcher is JavaScript, not shell. Check it when a JS engine is around.
if command -v node >/dev/null 2>&1; then
    node --check "$ROOT/clipboard-bridge/clipbridge.js" >/dev/null \
        || { echo "clipbridge.js failed a JavaScript syntax check" >&2; exit 1; }
fi

help_output="$($ROOT/ai-box --help)"
case "$help_output" in
    *"aibox"*"dev"*"build"*"status"*) ;;
    *)
        echo "ai-box help output is missing expected commands" >&2
        exit 1
        ;;
esac

test -f "$ROOT/README.md"
test -f "$ROOT/README.en.md"
test -f "$ROOT/LICENSE"

# Exercise custom environment forwarding without requiring Apple container. Keep the
# fixture self-contained so config, credentials, caches, and env-files never touch the checkout.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aibox-smoke.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

FIXTURE="$TMP_ROOT/repo"
STUB_BIN="$TMP_ROOT/bin"
TEST_HOME="$TMP_ROOT/home"
RUN_TMP="$TMP_ROOT/runtime-tmp"
PROJECT="$TMP_ROOT/project"
STUB_ARGS="$TMP_ROOT/container.args"
STUB_CALLED="$TMP_ROOT/container.called"
STUB_ENV_COPY="$TMP_ROOT/container.env-copy"
STUB_ENV_PATH="$TMP_ROOT/container.env-path"
STUB_ENV_MODE="$TMP_ROOT/container.env-mode"
STUB_HOST_ENV="$TMP_ROOT/container.host-env"
STUB_CALLS="$TMP_ROOT/container.calls"
STUB_ENV_LOG="$TMP_ROOT/container.env-log"
STUB_LS_RUNNING=""
STUB_LS_ALL=""
STUB_MACHINE_LIST=""
STUB_MACHINE_LIST_FAIL=0
STUB_IMAGE_PRESENT=1
STUB_MACHINE_INSPECT_JSON='[{"cpus":6,"createdDate":"2026-08-16T15:22:49Z","diskSize":2691284992,"homeMount":"rw","id":"aibox-dev","image":{"reference":"ai-sandbox-dev:latest"},"ipAddress":"192.168.65.5","memory":8589934592,"platform":{"architecture":"arm64","os":"linux"},"startedDate":"2026-08-16T15:22:50Z","status":"running","userSetup":{"gid":20,"uid":501,"username":"developer"}}]'
STUB_MACHINE_INSPECT_FAIL=0
STUB_DEV_SYSTEMD_FAIL=0
ORIGINAL_PATH="$PATH"
HOST_STUB_PATH="$STUB_BIN:$ORIGINAL_PATH"

mkdir -p "$FIXTURE" "$STUB_BIN" "$TEST_HOME" "$RUN_TMP" "$PROJECT"
cp "$ROOT/ai-box" "$ROOT/Dockerfile" "$ROOT/Dockerfile.dev" \
    "$ROOT/entrypoint.sh" "$ROOT/dev-profile.sh" "$ROOT/dev-shell.sh" \
    "$ROOT/dev-configure.sh" "$ROOT/dev-proxy-run.sh" "$ROOT/dev-tools.sh" "$FIXTURE/"
cp -R "$ROOT/clipboard-bridge" "$FIXTURE/clipboard-bridge"

cat > "$STUB_BIN/container" <<'STUB'
#!/usr/bin/env bash
set -eu

: > "$STUB_CALLED"
: > "$STUB_ARGS"
: > "$STUB_ENV_PATH"

{
    printf 'CALL'
    for arg in "$@"; do printf ' %s' "$arg"; done
    printf '\n'
} >> "$STUB_CALLS"

if [ "${1:-}" = "machine" ] && [ "${2:-}" = "list" ]; then
    if [ "${STUB_MACHINE_LIST_FAIL:-0}" -eq 1 ]; then
        echo "machine service unavailable" >&2
        exit 1
    fi
    [ -z "${STUB_MACHINE_LIST:-}" ] || printf '%s\n' "$STUB_MACHINE_LIST"
    exit 0
fi

if [ "${1:-}" = "machine" ] && [ "${2:-}" = "inspect" ]; then
    if [ "${STUB_MACHINE_INSPECT_FAIL:-0}" -eq 1 ]; then
        echo "machine inspect unavailable" >&2
        exit 1
    fi
    printf '%s\n' "$STUB_MACHINE_INSPECT_JSON"
    exit 0
fi

if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
    [ "${STUB_IMAGE_PRESENT:-1}" -eq 1 ]
    exit $?
fi

if [ "${1:-}" = "machine" ] && [ "${2:-}" = "run" ]; then
    for arg in "$@"; do
        case "$arg" in
            *'aibox dev systemd readiness timed out'*)
                if [ "${STUB_DEV_SYSTEMD_FAIL:-0}" -eq 1 ]; then
                    echo "aibox dev systemd readiness timed out" >&2
                    exit 1
                fi
                ;;
        esac
    done
fi

if [ "${1:-}" = "ls" ]; then
    list_output="${STUB_LS_RUNNING:-}"
    for arg in "$@"; do
        if [ "$arg" = "-a" ] || [ "$arg" = "--all" ]; then
            list_output="${STUB_LS_ALL:-}"
        fi
    done
    [ -z "$list_output" ] || printf '%s\n' "$list_output"
    exit 0
fi

env_file=""
expect_env_file=0
for arg in "$@"; do
    printf '%s\n' "$arg" >> "$STUB_ARGS"
    if [ "$expect_env_file" -eq 1 ]; then
        env_file="$arg"
        expect_env_file=0
        continue
    fi
    case "$arg" in
        --env-file)
            expect_env_file=1
            ;;
        *:/run/aibox/user-env:ro)
            env_file="${arg%:/run/aibox/user-env:ro}"
            ;;
    esac
done

{
    printf 'PATH=%s\n' "$PATH"
    printf 'HOME=%s\n' "$HOME"
} > "$STUB_HOST_ENV"

if [ -n "$env_file" ]; then
    printf '%s\n' "$env_file" > "$STUB_ENV_PATH"
    cp "$env_file" "$STUB_ENV_COPY"
    if env_mode="$(stat -f '%Lp' "$env_file" 2>/dev/null)"; then
        :
    else
        env_mode="$(stat -c '%a' "$env_file")"
    fi
    printf '%s\n' "$env_mode" > "$STUB_ENV_MODE"
    {
        printf 'ENV_FOR'
        for arg in "$@"; do printf ' %s' "$arg"; done
        printf '\n'
        cat "$env_file"
        printf 'END_ENV\n'
    } >> "$STUB_ENV_LOG"
fi
STUB
chmod +x "$STUB_BIN/container" "$FIXTURE/ai-box" "$FIXTURE/entrypoint.sh"

fail() {
    echo "smoke test failed: $1" >&2
    exit 1
}

assert_file_has_line() {
    grep -qxF -- "$2" "$1" || fail "$3"
}

assert_file_contains() {
    grep -qF -- "$2" "$1" || fail "$3"
}

assert_file_omits() {
    if grep -qF -- "$2" "$1"; then
        fail "$3"
    fi
}

assert_arg_pair() {
    expected_flag="$1"
    expected_value="$2"
    expect_value=0
    pair_found=0
    while IFS= read -r arg; do
        if [ "$expect_value" -eq 1 ]; then
            if [ "$arg" = "$expected_value" ]; then
                pair_found=1
                break
            fi
            expect_value=0
        fi
        if [ "$arg" = "$expected_flag" ]; then
            expect_value=1
        fi
    done < "$STUB_ARGS"
    [ "$pair_found" -eq 1 ] || fail "container argv is missing the expected $expected_flag pair"
}

arg_value_after() {
    expected_flag="$1"
    expect_value=0
    while IFS= read -r arg; do
        if [ "$expect_value" -eq 1 ]; then
            printf '%s\n' "$arg"
            return 0
        fi
        if [ "$arg" = "$expected_flag" ]; then
            expect_value=1
        fi
    done < "$STUB_ARGS"
    return 1
}

reset_stub_files() {
    rm -f "$STUB_ARGS" "$STUB_CALLED" "$STUB_ENV_COPY" "$STUB_ENV_PATH" \
        "$STUB_ENV_MODE" "$STUB_HOST_ENV" "$STUB_CALLS"
    rm -f "$STUB_ENV_LOG"
}

run_fixture() (
    export HOME="$TEST_HOME"
    export PATH="$HOST_STUB_PATH"
    export TMPDIR="$RUN_TMP"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export STUB_CALLS STUB_ENV_LOG STUB_LS_RUNNING STUB_LS_ALL STUB_MACHINE_LIST STUB_MACHINE_LIST_FAIL STUB_IMAGE_PRESENT
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL
    export ANTHROPIC_API_KEY="host-anthropic-key-must-not-be-forwarded"
    unset OPENAI_API_KEY AIBOX_PROXY AIBOX_TZ AIBOX_LANG
    unset FIXED_SOCKS_HOST FIXED_SOCKS_PORT FIXED_SOCKS_USER FIXED_SOCKS_PASS
    "$FIXTURE/ai-box" "$PROJECT"
)

run_fixture_command() (
    export HOME="$TEST_HOME"
    export PATH="$HOST_STUB_PATH"
    export TMPDIR="$RUN_TMP"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export STUB_CALLS STUB_ENV_LOG STUB_LS_RUNNING STUB_LS_ALL STUB_MACHINE_LIST STUB_MACHINE_LIST_FAIL STUB_IMAGE_PRESENT
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL
    "$FIXTURE/ai-box" "$@"
)

# An explicitly empty indexed array must work under macOS Bash 3.2 + set -u and must
# not create or mount an env-file.
cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_PROXY=""
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_ENV_VARS=()
CONF
reset_stub_files
run_fixture > "$TMP_ROOT/empty.output" 2>&1 || fail "empty AIBOX_ENV_VARS launch failed"
[ -f "$STUB_CALLED" ] || fail "container stub was not called for an empty array"
assert_file_omits "$STUB_ARGS" '--env-file' \
    "empty AIBOX_ENV_VARS unexpectedly passed an env-file"
assert_file_omits "$STUB_ARGS" '/run/aibox/user-env' \
    "empty AIBOX_ENV_VARS unexpectedly mounted an env-file"
assert_file_omits "$STUB_ARGS" 'ANTHROPIC_API_KEY' \
    "unlisted host ANTHROPIC_API_KEY was forwarded"
assert_arg_pair --label 'com.simpletang.ai-sandbox.managed=true'
assert_arg_pair --label 'com.simpletang.ai-sandbox.project=project'
assert_file_omits "$STUB_ARGS" 'CAP_NET_ADMIN' \
    "direct mode unexpectedly requested CAP_NET_ADMIN"
container_name="$(arg_value_after --name)" || fail "container argv is missing --name"
printf '%s\n' "$container_name" | grep -Eq '^aibox-project-[0-9]{6}-[0-9]+$' \
    || fail "container name is outside the dedicated aibox namespace"
if find "$RUN_TMP" -type f -name 'aibox-env.*' | grep -q .; then
    fail "empty AIBOX_ENV_VARS left an env-file"
fi

# Values live only in the temporary env-file. PATH and HOME are intentionally included
# to prove they do not alter how the host-side launcher finds the container stub or caches.
cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_PROXY=""
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_ENV_VARS=(
    'SPACE_VALUE=alpha beta gamma'
    'JSON_VALUE={"kind":"smoke","expression":"left=right"}'
    'EQUALS_VALUE=left=middle=right'
    'EMPTY_VALUE='
    'PATH=/container-only/bin'
    'HOME=/container-only/home'
)
CONF
cat > "$TMP_ROOT/expected.env" <<'ENVFILE'
SPACE_VALUE=alpha beta gamma
JSON_VALUE={"kind":"smoke","expression":"left=right"}
EQUALS_VALUE=left=middle=right
EMPTY_VALUE=
PATH=/container-only/bin
HOME=/container-only/home
ENVFILE

reset_stub_files
run_fixture > "$TMP_ROOT/valid.output" 2>&1 || fail "valid AIBOX_ENV_VARS launch failed"
[ -f "$STUB_CALLED" ] || fail "container stub was not called for valid config"
[ -f "$STUB_ENV_COPY" ] || fail "container stub did not copy the env-file"
cmp -s "$TMP_ROOT/expected.env" "$STUB_ENV_COPY" || fail "env-file content was not preserved"
assert_file_has_line "$STUB_ENV_MODE" '600' "env-file permissions were not 0600"
assert_file_has_line "$STUB_HOST_ENV" "PATH=$HOST_STUB_PATH" \
    "custom PATH affected the host container process"
assert_file_has_line "$STUB_HOST_ENV" "HOME=$TEST_HOME" \
    "custom HOME affected the host container process"

env_file_path="$(sed -n '1p' "$STUB_ENV_PATH")"
[ -n "$env_file_path" ] || fail "container stub did not record the env-file path"
assert_file_omits "$STUB_ARGS" '--env-file' \
    "custom environment was injected into the root entrypoint"
assert_arg_pair -v "$env_file_path:/run/aibox/user-env:ro"
[ ! -e "$env_file_path" ] || fail "launcher did not remove the env-file after container returned"
if find "$RUN_TMP" -type f -name 'aibox-env.*' | grep -q .; then
    fail "launcher left an unrecorded env-file"
fi

for custom_name in SPACE_VALUE JSON_VALUE EQUALS_VALUE EMPTY_VALUE PATH HOME; do
    assert_file_omits "$STUB_ARGS" "$custom_name=" \
        "custom assignment leaked into container argv"
done
assert_file_omits "$STUB_ARGS" 'alpha beta gamma' \
    "space-containing secret appeared as a container argument"
assert_file_omits "$STUB_ARGS" '{"kind":"smoke","expression":"left=right"}' \
    "JSON secret appeared as a container argument"
assert_file_omits "$STUB_ARGS" 'left=middle=right' \
    "equals-containing secret appeared as a container argument"
assert_file_omits "$STUB_ARGS" '/container-only/bin' \
    "custom PATH appeared as a container argument"
assert_file_omits "$STUB_ARGS" '/container-only/home' \
    "custom HOME appeared as a container argument"
assert_file_omits "$STUB_ARGS" 'ANTHROPIC_API_KEY' \
    "unlisted host ANTHROPIC_API_KEY was forwarded"
assert_file_omits "$STUB_ARGS" 'host-anthropic-key-must-not-be-forwarded' \
    "host ANTHROPIC_API_KEY value leaked into container argv"

# Proxy mode must request only the capability needed for the entrypoint firewall.
cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_PROXY="socks5h://proxy.example.invalid:1080"
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_ENV_VARS=()
CONF
reset_stub_files
run_fixture > "$TMP_ROOT/proxy.output" 2>&1 || fail "proxy-mode launch failed"
assert_arg_pair --cap-add CAP_NET_ADMIN
assert_arg_pair --label 'com.simpletang.ai-sandbox.managed=true'

# Legacy ai-* and other names must never enter the managed container list.
STUB_LS_RUNNING="aibox-alpha-project-120000-101
ai-legacy-project-120000
unrelated-container"
STUB_LS_ALL="$STUB_LS_RUNNING"
run_fixture_command list > "$TMP_ROOT/list.output" 2>&1 || fail "managed list failed"
assert_file_contains "$TMP_ROOT/list.output" 'aibox-alpha-project-120000-101' \
    "managed aibox container was omitted from list"
assert_file_omits "$TMP_ROOT/list.output" 'ai-legacy-project-120000' \
    "legacy ai-* container leaked into managed list"
assert_file_omits "$TMP_ROOT/list.output" 'unrelated-container' \
    "unrelated container leaked into managed list"

reset_stub_files
STUB_LS_RUNNING="aibox-alpha-project-120000-101"
run_fixture_command enter 1 > "$TMP_ROOT/enter.output" 2>&1 \
    || fail "entering a managed container failed"
assert_arg_pair -u root
assert_arg_pair -w '/workspace/alpha-project'
assert_file_contains "$STUB_ARGS" '/usr/local/sbin/aibox-enter-shell' \
    "enter did not use the trusted privilege-drop helper"
STUB_LS_RUNNING=""
STUB_LS_ALL=""

# The persistent development machine is created once, then machine run handles both
# booting a stopped machine and opening its login shell.
cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_PROXY="socks5h://dev-proxy.example.invalid:1080"
AIBOX_TZ="Asia/Shanghai"
AIBOX_LANG="zh_CN.UTF-8"
AIBOX_ENV_VARS=(
    'DEV_SECRET=dev secret with spaces'
)
CONF
reset_stub_files
STUB_MACHINE_LIST=""
STUB_IMAGE_PRESENT=1
run_fixture_command dev > "$TMP_ROOT/dev-create.output" 2>&1 \
    || fail "first persistent development-machine launch failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine create --name aibox-dev --memory 8192M --home-mount rw ai-sandbox-dev:latest' \
    "dev did not create the expected persistent machine"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --interactive --tty --name aibox-dev' \
    "dev did not enter the persistent machine"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev --root --env-file' \
    "dev did not configure machine-wide services through a root-only environment"
assert_file_contains "$STUB_CALLS" 'systemctl show --property=SystemState --value' \
    "dev did not wait for systemd after booting the machine"
assert_file_contains "$STUB_CALLS" '/usr/local/sbin/aibox-dev-configure' \
    "dev did not run the trusted machine configuration helper"
systemd_ready_line="$(grep -n -m 1 'systemctl show --property=SystemState --value' "$STUB_CALLS" | cut -d: -f1)"
system_config_line="$(grep -n -m 1 '/usr/local/sbin/aibox-dev-configure' "$STUB_CALLS" | cut -d: -f1)"
if (( systemd_ready_line >= system_config_line )); then
    fail "dev applied system configuration before systemd was ready"
fi
assert_file_contains "$STUB_CALLS" '--env-file' \
    "dev did not inject its environment through an env-file"
assert_file_omits "$STUB_CALLS" '--rm' \
    "persistent machine creation unexpectedly requested automatic removal"
assert_file_omits "$STUB_CALLS" 'dev-proxy.example.invalid' \
    "dev proxy credentials leaked into container argv"
assert_file_omits "$STUB_CALLS" 'dev secret with spaces' \
    "dev custom environment leaked into container argv"
assert_file_contains "$STUB_ENV_COPY" 'AIBOX_PROXY=socks5h://dev-proxy.example.invalid:1080' \
    "dev proxy was omitted from its env-file"
assert_file_contains "$STUB_ENV_COPY" 'AIBOX_TZ=Asia/Shanghai' \
    "dev timezone was omitted from its env-file"
assert_file_contains "$STUB_ENV_COPY" 'AIBOX_LANG=zh_CN.UTF-8' \
    "dev locale was omitted from its env-file"
assert_file_contains "$STUB_ENV_COPY" 'DEV_SECRET=dev secret with spaces' \
    "dev custom environment was omitted from its env-file"
root_env_block="$(awk '
    /^ENV_FOR machine run --name aibox-dev --root / { capture = 1 }
    capture { print }
    capture && /^END_ENV$/ { exit }
' "$STUB_ENV_LOG")"
case "$root_env_block" in
    *'DEV_SECRET='*) fail "dev custom environment reached the root configuration process" ;;
esac
case "$root_env_block" in
    *'AIBOX_TZ=Asia/Shanghai'*) ;;
    *) fail "dev root configuration did not receive the resolved timezone" ;;
esac
case "$root_env_block" in
    *'AIBOX_LANG='*) fail "dev locale reached the root configuration process" ;;
esac
case "$root_env_block" in
    *'AIBOX_PROXY=socks5h://dev-proxy.example.invalid:1080'*) ;;
    *) fail "dev root configuration did not receive the proxy setting" ;;
esac
assert_file_has_line "$STUB_ENV_MODE" '600' "dev env-file permissions were not 0600"
dev_env_file_path="$(sed -n '1p' "$STUB_ENV_PATH")"
[ ! -e "$dev_env_file_path" ] || fail "dev launcher did not remove its env-file"
if find "$RUN_TMP" -type f \( -name 'aibox-dev-env.*' -o -name 'aibox-dev-system.*' \) | grep -q .; then
    fail "dev launcher left a temporary environment file"
fi

reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
run_fixture_command dev > "$TMP_ROOT/dev-existing.output" 2>&1 \
    || fail "existing persistent development-machine launch failed"
assert_file_omits "$STUB_CALLS" 'CALL machine create' \
    "existing persistent machine was recreated"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --interactive --tty --name aibox-dev' \
    "existing persistent machine was not entered"

reset_stub_files
run_fixture_command dev start > "$TMP_ROOT/dev-start.output" 2>&1 \
    || fail "starting the persistent machine without a shell failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev --root --env-file' \
    "dev start did not apply machine configuration"
assert_file_omits "$STUB_CALLS" '/usr/local/bin/aibox-dev-shell' \
    "dev start unexpectedly opened a login shell"

reset_stub_files
STUB_DEV_SYSTEMD_FAIL=1
if run_fixture_command dev start > "$TMP_ROOT/dev-systemd-timeout.output" 2>&1; then
    fail "dev start ignored a systemd readiness timeout"
fi
assert_file_contains "$TMP_ROOT/dev-systemd-timeout.output" \
    '持久开发机启动后 systemd 未能在 30 秒内就绪' \
    "dev start did not explain its systemd readiness failure"
assert_file_omits "$STUB_CALLS" '/usr/local/sbin/aibox-dev-configure' \
    "dev configured the machine after systemd readiness failed"
assert_file_omits "$STUB_CALLS" '/usr/local/bin/aibox-dev-shell' \
    "dev opened a login shell after systemd readiness failed"
STUB_DEV_SYSTEMD_FAIL=0

reset_stub_files
run_fixture_command dev restart > "$TMP_ROOT/dev-restart.output" 2>&1 \
    || fail "restarting the persistent machine failed"
assert_file_contains "$STUB_CALLS" 'CALL machine stop aibox-dev' \
    "dev restart did not stop the machine first"
assert_file_contains "$STUB_CALLS" '/usr/local/sbin/aibox-dev-configure' \
    "dev restart did not reapply machine configuration"

reset_stub_files
run_fixture_command dev exec printf hello > "$TMP_ROOT/dev-exec.output" 2>&1 \
    || fail "executing a command in the persistent machine failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --interactive --tty --name aibox-dev' \
    "dev exec did not allocate an interactive machine process"
assert_file_contains "$STUB_CALLS" \
    '/usr/local/bin/aibox-dev-shell printf hello' \
    "dev exec did not pass the requested command through the environment wrapper"

reset_stub_files
run_fixture_command dev update cc > "$TMP_ROOT/dev-update.output" 2>&1 \
    || fail "updating Claude in the persistent machine failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev --root /usr/local/sbin/aibox-dev-tools update claude' \
    "dev update did not target the machine-local Claude installation"

reset_stub_files
run_fixture_command dev version codex > "$TMP_ROOT/dev-version.output" 2>&1 \
    || fail "reading the persistent machine Codex version failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev /usr/local/sbin/aibox-dev-tools version codex' \
    "dev version did not inspect the machine-local Codex installation"

reset_stub_files
run_fixture_command dev set memory=12G cpus=6 > "$TMP_ROOT/dev-set.output" 2>&1 \
    || fail "setting persistent machine resources failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine set --name aibox-dev memory=12G cpus=6' \
    "dev set did not forward validated machine resources"

reset_stub_files
if run_fixture_command dev set home-mount=none > "$TMP_ROOT/dev-set-invalid.output" 2>&1; then
    fail "dev set accepted a setting outside the aibox resource contract"
fi
assert_file_omits "$STUB_CALLS" 'CALL machine set' \
    "invalid dev set reached the container CLI"

reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
STUB_MACHINE_INSPECT_FAIL=0
run_fixture_command dev status > "$TMP_ROOT/dev-status.output" 2>&1 \
    || fail "reading the persistent machine status failed"
assert_file_contains "$TMP_ROOT/dev-status.output" '== 持久开发机状态 ==' \
    "dev status is missing its readable heading"
assert_file_contains "$TMP_ROOT/dev-status.output" '运行状态   : 运行中' \
    "dev status did not translate the machine state"
assert_file_contains "$TMP_ROOT/dev-status.output" '镜像       : ai-sandbox-dev:latest' \
    "dev status did not show the machine image"
assert_file_contains "$TMP_ROOT/dev-status.output" '平台       : linux/arm64' \
    "dev status did not format the machine platform"
assert_file_contains "$TMP_ROOT/dev-status.output" 'CPU        : 6 核' \
    "dev status did not format the CPU allocation"
assert_file_contains "$TMP_ROOT/dev-status.output" '内存       : 8 GiB' \
    "dev status did not format the memory allocation"
assert_file_contains "$TMP_ROOT/dev-status.output" '系统盘     : 2.5 GiB（持久保留）' \
    "dev status did not format the persistent disk size"
assert_file_contains "$TMP_ROOT/dev-status.output" 'IP 地址    : 192.168.65.5' \
    "dev status did not show the machine IP address"
assert_file_contains "$TMP_ROOT/dev-status.output" 'Home 挂载  : 读写（宿主 Home）' \
    "dev status omitted the host home mount mode"
assert_file_contains "$TMP_ROOT/dev-status.output" '开发用户   : developer（UID 501 / GID 20）' \
    "dev status did not format the provisioned user"
assert_file_contains "$TMP_ROOT/dev-status.output" '启动时间   : 2026-08-16T15:22:50Z' \
    "dev status did not show the last start time"
assert_file_omits "$TMP_ROOT/dev-status.output" '[{"cpus"' \
    "dev status leaked raw inspect JSON"

reset_stub_files
STUB_MACHINE_INSPECT_FAIL=1
if run_fixture_command dev status > "$TMP_ROOT/dev-status-inspect-error.output" 2>&1; then
    fail "dev status treated an inspect failure as success"
fi
assert_file_contains "$TMP_ROOT/dev-status-inspect-error.output" 'machine inspect unavailable' \
    "dev status hid the machine inspect failure"
STUB_MACHINE_INSPECT_FAIL=0

reset_stub_files
STUB_MACHINE_LIST_FAIL=1
if run_fixture_command dev status > "$TMP_ROOT/dev-status-error.output" 2>&1; then
    fail "dev status treated a machine query failure as success"
fi
assert_file_contains "$TMP_ROOT/dev-status-error.output" 'machine service unavailable' \
    "dev status hid the machine query failure"
assert_file_omits "$TMP_ROOT/dev-status-error.output" '尚未创建' \
    "dev status misreported a query failure as a missing machine"
STUB_MACHINE_LIST_FAIL=0

reset_stub_files
run_fixture_command dev stop > "$TMP_ROOT/dev-stop.output" 2>&1 \
    || fail "stopping the persistent development machine failed"
assert_file_contains "$STUB_CALLS" 'CALL machine stop aibox-dev' \
    "dev stop did not target the persistent machine"
assert_file_omits "$STUB_CALLS" 'CALL machine delete' \
    "dev stop deleted persistent storage"

reset_stub_files
printf 'n\n' | run_fixture_command dev delete > "$TMP_ROOT/dev-delete-cancel.output" 2>&1 \
    || fail "cancelling persistent machine deletion failed"
assert_file_omits "$STUB_CALLS" 'CALL machine delete' \
    "dev delete ignored a negative confirmation"

reset_stub_files
printf 'y\n' | run_fixture_command dev delete > "$TMP_ROOT/dev-delete.output" 2>&1 \
    || fail "deleting the persistent development machine failed"
assert_file_contains "$STUB_CALLS" 'CALL machine delete aibox-dev' \
    "confirmed dev delete did not target the persistent machine"

reset_stub_files
STUB_MACHINE_LIST=""
STUB_IMAGE_PRESENT=0
if run_fixture_command dev > "$TMP_ROOT/dev-missing-image.output" 2>&1; then
    fail "dev unexpectedly launched without its machine image"
fi
assert_file_contains "$TMP_ROOT/dev-missing-image.output" 'aibox dev build' \
    "missing development-machine image error did not explain how to build it"
assert_file_omits "$STUB_CALLS" 'CALL machine create' \
    "dev attempted machine creation without its image"

reset_stub_files
STUB_IMAGE_PRESENT=1
run_fixture_command build --no-cache > "$TMP_ROOT/build.output" 2>&1 \
    || fail "ephemeral image build command failed"
assert_file_contains "$STUB_CALLS" \
    'CALL build --no-cache -t ai-sandbox:latest .' \
    "build omitted the ephemeral image"
assert_file_omits "$STUB_CALLS" 'Dockerfile.dev' \
    "build unexpectedly rebuilt the persistent development-machine image"

reset_stub_files
run_fixture_command dev build --no-cache > "$TMP_ROOT/dev-build.output" 2>&1 \
    || fail "development-machine image build command failed"
assert_file_contains "$STUB_CALLS" \
    'CALL build --no-cache -f Dockerfile.dev --build-arg BASE_IMAGE=ai-sandbox:latest -t ai-sandbox-dev:latest .' \
    "dev build omitted the persistent development-machine image"
assert_file_omits "$STUB_CALLS" 'CALL build --no-cache -t ai-sandbox:latest .' \
    "dev build unexpectedly rebuilt the ephemeral image"

reset_stub_files
STUB_IMAGE_PRESENT=0
if run_fixture_command dev build > "$TMP_ROOT/dev-build-missing-base.output" 2>&1; then
    fail "dev build unexpectedly succeeded without its local base image"
fi
assert_file_contains "$TMP_ROOT/dev-build-missing-base.output" '请先运行 aibox build' \
    "dev build did not explain how to create its missing base image"
assert_file_omits "$STUB_CALLS" 'CALL build' \
    "dev build reached the builder without its local base image"
STUB_IMAGE_PRESENT=1
STUB_MACHINE_LIST=""

assert_rejected_before_container() {
    case_name="$1"
    secret_fragment="$2"
    reset_stub_files
    if run_fixture > "$TMP_ROOT/$case_name.output" 2>&1; then
        fail "$case_name config unexpectedly succeeded"
    fi
    [ ! -e "$STUB_CALLED" ] || fail "$case_name reached container before validation failed"
    assert_file_contains "$TMP_ROOT/$case_name.output" 'AIBOX_ENV_VARS' \
        "$case_name error did not identify AIBOX_ENV_VARS"
    assert_file_omits "$TMP_ROOT/$case_name.output" "$secret_fragment" \
        "$case_name error leaked the rejected value"
    if find "$RUN_TMP" -type f -name 'aibox-env.*' | grep -q .; then
        fail "$case_name left an env-file"
    fi
}

cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_ENV_VARS=(
    'BAD-NAME=invalid-name-value-must-stay-secret'
)
CONF
assert_rejected_before_container invalid-name 'invalid-name-value-must-stay-secret'

cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_ENV_VARS=(
    'AIBOX_PRIVATE=reserved-name-value-must-stay-secret'
)
CONF
assert_rejected_before_container reserved-name 'reserved-name-value-must-stay-secret'

cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_ENV_VARS=(
    $'CR_VALUE=cr-value-must-stay-secret\rsecond-line'
)
CONF
assert_rejected_before_container carriage-return 'cr-value-must-stay-secret'

cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_ENV_VARS=(
    $'LF_VALUE=lf-value-must-stay-secret\nsecond-line'
)
CONF
assert_rejected_before_container line-feed 'lf-value-must-stay-secret'

grep -qF -- '-m owner --uid-owner "$GOST_UID" -j ACCEPT' "$ROOT/network-lockdown.sh" \
    || fail "network lockdown does not isolate gost by UID"
grep -qF -- '-A AIBOX_OUTPUT -j REJECT' "$ROOT/network-lockdown.sh" \
    || fail "network lockdown is missing its fail-closed rule"
grep -qF -- '--bounding-set=-all --no-new-privs' "$ROOT/enter-shell.sh" \
    || fail "enter helper does not drop proxy-container privileges"
grep -qF -- '/run/aibox/proxy-lockdown' "$ROOT/enter-shell.sh" \
    || fail "enter helper does not distinguish proxy lockdown mode"
tail -n 1 "$ROOT/Dockerfile.update" | grep -qxF 'USER root' \
    || fail "incremental update would bypass root entrypoint initialization"
grep -qF 'ENTRYPOINT ["/sbin/init"]' "$ROOT/Dockerfile.dev" \
    || fail "development-machine image does not boot /sbin/init"
grep -qF 'export CLAUDE_CONFIG_DIR="$HOME/.claude"' "$ROOT/dev-profile.sh" \
    || fail "development-machine profile still points Claude at the ephemeral node user"
grep -qF 'systemctl restart aibox-dev-proxy.service' "$ROOT/dev-configure.sh" \
    || fail "development-machine configuration does not refresh its proxy service"
grep -qF 'systemctl show --property=SystemState --value' "$ROOT/dev-configure.sh" \
    || fail "development-machine configuration does not wait for systemd readiness"
grep -qF 'chmod 0711 /run/aibox' "$ROOT/dev-configure.sh" \
    || fail "development-machine proxy user cannot traverse its runtime directory"
grep -qF 'ln -snf "/usr/share/zoneinfo/$system_tz" /etc/localtime' "$ROOT/dev-configure.sh" \
    || fail "development-machine configuration does not set the system timezone"
grep -qF "printf '%s\\n' \"\$system_tz\" > /etc/timezone" "$ROOT/dev-configure.sh" \
    || fail "development-machine configuration does not persist the timezone name"
grep -qF 'http://127.0.0.1:8080' "$ROOT/dev-shell.sh" \
    || fail "development-machine shell does not export the local proxy endpoint"
head -n 1 "$ROOT/dev-shell.sh" | grep -qxF '#!/bin/bash' \
    || fail "development-machine shell still depends on a custom PATH to find bash"
grep -qF 'exec /bin/bash -l' "$ROOT/dev-shell.sh" \
    || fail "development-machine login still depends on a custom PATH to find bash"
grep -qF '/usr/local/sbin/aibox-dev-proxy-run' "$ROOT/aibox-dev-proxy.service" \
    || fail "development-machine proxy is not managed by systemd"
grep -qF '@anthropic-ai/claude-code@latest' "$ROOT/dev-tools.sh" \
    || fail "development-machine updater omits Claude Code"
grep -qF '@openai/codex@latest' "$ROOT/dev-tools.sh" \
    || fail "development-machine updater omits Codex"

# Execute the dev environment wrapper with an absolute command. A custom PATH
# must not prevent the trusted wrapper itself from starting.
DEV_SHELL_RESULT="$TMP_ROOT/dev-shell.result"
PATH="/container-only/bin" \
AIBOX_PROXY="socks5h://proxy.example.invalid:1080" \
AIBOX_TZ="UTC" AIBOX_LANG="C.UTF-8" \
AIBOX_DEV_CUSTOM_NAMES="TZ,HTTP_PROXY,PATH" \
TZ="Custom/Timezone" HTTP_PROXY="http://custom.example.invalid:3128" \
    /bin/bash "$ROOT/dev-shell.sh" /usr/bin/env > "$DEV_SHELL_RESULT" \
    || fail "development-machine login environment setup failed"
assert_file_has_line "$DEV_SHELL_RESULT" 'PATH=/container-only/bin' \
    "dev custom PATH was not preserved"
assert_file_has_line "$DEV_SHELL_RESULT" 'TZ=Custom/Timezone' \
    "dev automatic timezone overrode an explicit custom TZ"
assert_file_has_line "$DEV_SHELL_RESULT" 'HTTP_PROXY=http://custom.example.invalid:3128' \
    "dev automatic proxy overrode an explicit custom HTTP_PROXY"
assert_file_has_line "$DEV_SHELL_RESULT" 'HTTPS_PROXY=http://127.0.0.1:8080' \
    "dev did not fill an unspecified standard proxy variable"
assert_file_omits "$DEV_SHELL_RESULT" 'AIBOX_PROXY=' \
    "dev exposed its upstream proxy setting to the final login shell"
assert_file_omits "$DEV_SHELL_RESULT" 'AIBOX_DEV_CUSTOM_NAMES=' \
    "dev exposed its internal custom-name metadata to the final login shell"

# The user env file is imported by the unprivileged command wrapper, not by root startup.
ENTRYPOINT_HOME="$TMP_ROOT/entrypoint-home"
ENTRYPOINT_RESULT="$TMP_ROOT/entrypoint-user-env.result"
BASH_ENV_MARKER="$TMP_ROOT/bash-env.marker"
BASH_ENV_HOOK="$TMP_ROOT/bash-env-hook"
DELAYED_ENV_FILE="$TMP_ROOT/delayed-user-env"
mkdir -p "$ENTRYPOINT_HOME/.m2" "$ENTRYPOINT_HOME/.gradle"
cat > "$BASH_ENV_HOOK" <<'HOOK'
printf '%s\n' "user-phase" > "$BASH_ENV_MARKER"
HOOK
cat > "$DELAYED_ENV_FILE" <<ENVFILE
DELAYED_VALUE=alpha beta gamma
HOME=/container-only/home
BASH_ENV=$BASH_ENV_HOOK
ENVFILE
export ENTRYPOINT_RESULT BASH_ENV_MARKER
AIBOX_USER_ENV_FILE="$DELAYED_ENV_FILE" \
AIBOX_NETWORK_SHOWN=test \
HOME="$ENTRYPOINT_HOME" \
AIBOX_PROXY="" AIBOX_TZ="" AIBOX_LANG="" AIBOX_PROJECT="" \
    "$ROOT/user-exec.sh" bash -c \
        'printf "%s\n%s\n" "$DELAYED_VALUE" "$HOME" > "$ENTRYPOINT_RESULT"' \
        > "$TMP_ROOT/entrypoint.output" 2>&1 \
    || fail "unprivileged user environment import failed"
cat > "$TMP_ROOT/expected-entrypoint.result" <<'EXPECTED'
alpha beta gamma
/container-only/home
EXPECTED
cmp -s "$TMP_ROOT/expected-entrypoint.result" "$ENTRYPOINT_RESULT" \
    || fail "user environment was not preserved after privilege drop"
[ -f "$BASH_ENV_MARKER" ] || fail "BASH_ENV did not reach the final user command"

# ---------------------------------------------------------------------------
# Clipboard image bridge
# ---------------------------------------------------------------------------
# The guest-side xclip shim is baked into the image; ai-box only has to make the
# host-side bridge directory reachable and tell the shim where it landed. The two
# run modes differ: aibox dev already mounts the whole host home at a matching
# path, while an ephemeral container mounts only the project directory and needs
# an extra read-only mount.

cat > "$FIXTURE/aibox.conf" <<'CONF'
AIBOX_PROXY=""
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_ENV_VARS=()
CONF

CLIP_BRIDGE="$TEST_HOME/.clipboard-bridge"
rm -rf "$CLIP_BRIDGE"

# Without the host-side watcher installed nothing is mounted and no variable is
# injected, so the shim falls back to reporting an empty clipboard.
reset_stub_files
run_fixture > "$TMP_ROOT/clip-absent.output" 2>&1 || fail "launch without a clipboard bridge failed"
assert_file_omits "$STUB_ARGS" 'clipboard-bridge' \
    "a clipboard bridge mount appeared without the host-side directory"
assert_file_omits "$STUB_ARGS" 'CLIP_BRIDGE_DIR' \
    "CLIP_BRIDGE_DIR was injected without the host-side directory"

# With the directory present the ephemeral container gets a read-only mount at a
# fixed path plus the matching variable.
mkdir -p "$CLIP_BRIDGE"
reset_stub_files
run_fixture > "$TMP_ROOT/clip-present.output" 2>&1 || fail "launch with a clipboard bridge failed"
assert_arg_pair -v "$CLIP_BRIDGE:/run/aibox/clipboard-bridge:ro"
assert_arg_pair -e 'CLIP_BRIDGE_DIR=/run/aibox/clipboard-bridge'

# When the project directory is the home directory itself, the bridge is already
# inside the project mount. Mounting the same host path twice trips the silent
# empty-mount problem, so the launcher must reuse the existing mount instead.
reset_stub_files
run_fixture_command "$TEST_HOME" > "$TMP_ROOT/clip-nested.output" 2>&1 \
    || fail "launch with the home directory as the project failed"
assert_file_omits "$STUB_ARGS" '/run/aibox/clipboard-bridge' \
    "the bridge was mounted twice when the project directory already contained it"
clip_nested_project="$(basename "$TEST_HOME")"
assert_arg_pair -e "CLIP_BRIDGE_DIR=/workspace/$clip_nested_project/.clipboard-bridge"

# The persistent development machine mounts the host home at a matching path, so
# the value travels through its env-file unchanged.
reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
run_fixture_command dev > "$TMP_ROOT/clip-dev.output" 2>&1 \
    || fail "persistent development-machine launch with a clipboard bridge failed"
assert_file_contains "$STUB_ENV_COPY" "CLIP_BRIDGE_DIR=$CLIP_BRIDGE" \
    "the clipboard bridge path was omitted from the dev env-file"
STUB_MACHINE_LIST=""

# aibox clip only accepts the four documented actions.
if run_fixture_command clip bogus > "$TMP_ROOT/clip-bogus.output" 2>&1; then
    fail "aibox clip accepted an unknown action"
fi
assert_file_contains "$TMP_ROOT/clip-bogus.output" 'install|uninstall|status|restart' \
    "aibox clip did not print its usage line for an unknown action"

# The launch agent must name the interpreter that matches the watcher it points
# at, otherwise osascript compiles JavaScript as AppleScript and the agent dies.
clip_plist_render() {
    sed -e "s|__SCRIPT__|$1|g" -e "s|__LANG__|$2|g" -e "s|__LOGDIR__|/tmp|g" \
        "$ROOT/clipboard-bridge/com.local.clipbridge.plist"
}
clip_plist_render '/x/clipbridge.js' 'JavaScript' > "$TMP_ROOT/clip-plist-jxa.xml"
assert_file_has_line "$TMP_ROOT/clip-plist-jxa.xml" '		<string>JavaScript</string>' \
    "the launch agent did not select the JavaScript interpreter"
assert_file_has_line "$TMP_ROOT/clip-plist-jxa.xml" '		<string>/x/clipbridge.js</string>' \
    "the launch agent did not point at the watcher script"
assert_file_omits "$TMP_ROOT/clip-plist-jxa.xml" '__' \
    "the launch agent template left an unreplaced placeholder"
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$TMP_ROOT/clip-plist-jxa.xml" >/dev/null \
        || fail "the rendered launch agent is not a valid property list"
fi

# Restarting has to re-render the launch agent. A bare `launchctl kickstart`
# restarts the job definition that is already loaded, so a changed watcher path
# or interpreter would be ignored and the old implementation would keep running.
# The installer refuses to execute off macOS, so assert on its source instead.
clip_installer_src="$ROOT/clipboard-bridge/install-host.sh"
assert_file_contains "$clip_installer_src" 'restart)   do_restart ;;' \
    "aibox clip restart is no longer routed through do_restart"
awk '/^do_restart\(\) \{/,/^\}$/' "$clip_installer_src" > "$TMP_ROOT/clip-restart.sh"
assert_file_contains "$TMP_ROOT/clip-restart.sh" 'do_install' \
    "aibox clip restart does not re-render the launch agent"
assert_file_omits "$TMP_ROOT/clip-restart.sh" 'kickstart' \
    "aibox clip restart fell back to kickstart, which keeps the stale job definition"

# launchctl bootout returns before launchd has finished unloading. Bootstrapping
# into that window fails with "Bootstrap failed: 5: Input/output error" and leaves
# the watcher unloaded, so the installer has to wait for the old job to disappear.
awk '/^do_install\(\) \{/,/^\}$/' "$clip_installer_src" > "$TMP_ROOT/clip-install.sh"
assert_file_contains "$TMP_ROOT/clip-install.sh" 'while launchctl print' \
    "the installer no longer waits for the old launch agent to unload"
assert_file_contains "$TMP_ROOT/clip-install.sh" 'until launchctl bootstrap' \
    "the installer no longer retries bootstrap"

# The status screen reports derived facts in aligned fields. Dumping raw
# `launchctl print` / `ls -l` output back into it is the regression to avoid.
awk '/^do_status\(\) \{/,/^\}$/' "$clip_installer_src" > "$TMP_ROOT/clip-status.sh"
assert_file_contains "$TMP_ROOT/clip-status.sh" 'clip_field' \
    "aibox clip status stopped using aligned fields"
assert_file_omits "$TMP_ROOT/clip-status.sh" 'ls -l' \
    "aibox clip status went back to dumping a raw directory listing"
for clip_state in '未启用' '已安装但未加载' '没有心跳' '心跳已停'; do
    assert_file_contains "$TMP_ROOT/clip-status.sh" "$clip_state" \
        "aibox clip status no longer reports the '$clip_state' state"
done

# The watcher must collapse a multi-step clipboard write into a single capture.
if command -v node >/dev/null 2>&1; then
    assert_file_contains "$ROOT/clipboard-bridge/clipbridge.js" 'SETTLE_MAX_ROUNDS' \
        "the watcher lost its clipboard-settling debounce"
fi

# Both status commands surface the bridge, so a broken host-side watcher is
# visible without having to remember a separate command.
rm -rf "$CLIP_BRIDGE"
reset_stub_files
run_fixture_command status > "$TMP_ROOT/clip-status-off.output" 2>&1 \
    || fail "aibox status failed without a clipboard bridge"
assert_file_contains "$TMP_ROOT/clip-status-off.output" '剪贴板贴图' \
    "aibox status did not report the clipboard bridge"
assert_file_contains "$TMP_ROOT/clip-status-off.output" '未启用' \
    "aibox status did not report an uninstalled clipboard bridge"

mkdir -p "$CLIP_BRIDGE"
: > "$CLIP_BRIDGE/alive"
reset_stub_files
run_fixture_command status > "$TMP_ROOT/clip-status-on.output" 2>&1 \
    || fail "aibox status failed with a clipboard bridge"
assert_file_contains "$TMP_ROOT/clip-status-on.output" '已启用' \
    "aibox status did not report a running clipboard bridge"

# A watcher that stopped updating its heartbeat must read as broken, not as
# working, otherwise Ctrl+V silently pastes whatever was copied hours ago.
touch -t 197001010000 "$CLIP_BRIDGE/alive" 2>/dev/null \
    || touch -d '1970-01-01 00:00' "$CLIP_BRIDGE/alive"
reset_stub_files
run_fixture_command status > "$TMP_ROOT/clip-status-stale.output" 2>&1 \
    || fail "aibox status failed with a stale clipboard bridge"
assert_file_contains "$TMP_ROOT/clip-status-stale.output" '异常' \
    "aibox status did not flag a stale clipboard-bridge heartbeat"
: > "$CLIP_BRIDGE/alive"

reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
run_fixture_command dev status > "$TMP_ROOT/clip-dev-status.output" 2>&1 \
    || fail "aibox dev status failed"
assert_file_contains "$TMP_ROOT/clip-dev-status.output" '剪贴板贴图' \
    "aibox dev status did not report the clipboard bridge"
STUB_MACHINE_LIST=""

# The shim must speak exactly the two commands Claude Code issues, and must stop
# serving a stale image once the host-side watcher stops updating its heartbeat.
CLIP_SHIM="$ROOT/clipboard-bridge/xclip-shim.sh"
CLIP_TEST_DIR="$TMP_ROOT/clip-shim"
mkdir -p "$CLIP_TEST_DIR"
printf '\211PNG\r\n\032\n fake png payload' > "$CLIP_TEST_DIR/clipboard.png"
printf 'image/png' > "$CLIP_TEST_DIR/targets"
: > "$CLIP_TEST_DIR/alive"

CLIP_BRIDGE_DIR="$CLIP_TEST_DIR" "$CLIP_SHIM" -selection clipboard -t TARGETS -o \
    | grep -qE 'image/(png|jpeg|jpg|gif|webp|bmp)' \
    || fail "the xclip shim did not advertise an available image"
CLIP_BRIDGE_DIR="$CLIP_TEST_DIR" "$CLIP_SHIM" -selection clipboard -t image/png -o \
    > "$CLIP_TEST_DIR/pasted.png" \
    || fail "the xclip shim did not emit the image"
cmp -s "$CLIP_TEST_DIR/clipboard.png" "$CLIP_TEST_DIR/pasted.png" \
    || fail "the xclip shim emitted altered image bytes"

# One image must be delivered once. Claude Code re-runs the shim on every Ctrl+V,
# and an impatient double-press would otherwise attach the same screenshot twice.
CLIP_STATE_DIR="$TMP_ROOT/clip-shim-state"
rm -rf "$CLIP_STATE_DIR"
clip_shim() {
    CLIP_BRIDGE_DIR="$CLIP_TEST_DIR" CLIP_BRIDGE_STATE="$CLIP_STATE_DIR" "$CLIP_SHIM" "$@"
}
clip_shim -selection clipboard -t image/png -o > /dev/null \
    || fail "the xclip shim did not deliver the image once"
if clip_shim -selection clipboard -t TARGETS -o | grep -qE 'image/'; then
    fail "the xclip shim re-offered an image it had already delivered"
fi
if clip_shim -selection clipboard -t image/png -o > /dev/null 2>&1; then
    fail "the xclip shim delivered the same image twice"
fi

# Copying again rewrites the file, so a fresh capture must become available even
# when the picture is identical.
sleep 1
printf '\211PNG\r\n\032\n fake png payload' > "$CLIP_TEST_DIR/clipboard.png"
clip_shim -selection clipboard -t TARGETS -o | grep -qE 'image/' \
    || fail "the xclip shim did not re-offer a freshly captured image"

# The bridge directory is mounted read-only for ephemeral containers, so the
# consumed marker has to live in container-local state, not next to the image.
chmod 500 "$CLIP_TEST_DIR"
rm -rf "$CLIP_STATE_DIR"
clip_shim -selection clipboard -t image/png -o > /dev/null \
    || fail "the xclip shim failed against a read-only bridge directory"
if clip_shim -selection clipboard -t TARGETS -o | grep -qE 'image/'; then
    fail "one-shot delivery stopped working against a read-only bridge directory"
fi
chmod 700 "$CLIP_TEST_DIR"

# Opting out restores plain clipboard semantics.
CLIP_BRIDGE_ONESHOT=0 clip_shim -selection clipboard -t TARGETS -o | grep -qE 'image/' \
    || fail "CLIP_BRIDGE_ONESHOT=0 did not restore repeatable pastes"
rm -rf "$CLIP_STATE_DIR"

# Clipboard text must never be mirrored, so text requests always fail.
if CLIP_BRIDGE_DIR="$CLIP_TEST_DIR" "$CLIP_SHIM" -selection clipboard -t text/plain -o \
    > /dev/null 2>&1; then
    fail "the xclip shim served clipboard text"
fi

# A missing image marker means the clipboard holds something else.
rm -f "$CLIP_TEST_DIR/targets"
if CLIP_BRIDGE_DIR="$CLIP_TEST_DIR" "$CLIP_SHIM" -selection clipboard -t TARGETS -o \
    | grep -qE 'image/'; then
    fail "the xclip shim advertised an image without its marker"
fi

# A stale heartbeat means the host-side watcher died; serving its last image would
# paste something the user copied long ago.
printf 'image/png' > "$CLIP_TEST_DIR/targets"
CLIP_STALE_REF="$TMP_ROOT/clip-stale-ref"
: > "$CLIP_STALE_REF"
CLIP_BRIDGE_STALE=0 CLIP_BRIDGE_DIR="$CLIP_TEST_DIR" sh -c '
    sleep 1
    if "$1" -selection clipboard -t TARGETS -o | grep -qE "image/"; then
        exit 1
    fi
' sh "$CLIP_SHIM" || fail "the xclip shim served an image after the heartbeat went stale"

echo "smoke tests passed"
