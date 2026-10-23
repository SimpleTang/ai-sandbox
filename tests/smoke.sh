#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n \
    "$ROOT/ai-box" \
    "$ROOT/setup.sh" \
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
    *"aibox"*"setup"*"build"*"aibox tmp"*"status"*) ;;
    *)
        echo "ai-box help output is missing expected commands" >&2
        exit 1
        ;;
esac

test -f "$ROOT/README.md"
test -f "$ROOT/README.en.md"
test -f "$ROOT/LICENSE"

# Every release version needs a changelog entry; the release workflow publishes that section.
aibox_version="$(sed -n 's/^AIBOX_VERSION="\(.*\)"$/\1/p' "$ROOT/ai-box")"
[ -n "$aibox_version" ] || { echo "ai-box does not declare AIBOX_VERSION" >&2; exit 1; }
grep -q "^## \[$aibox_version\]" "$ROOT/CHANGELOG.md" \
    || { echo "CHANGELOG.md has no entry for $aibox_version" >&2; exit 1; }
case "$("$ROOT/ai-box" --version)" in
    "aibox $aibox_version"*) ;;
    *) echo "ai-box --version does not report $aibox_version" >&2; exit 1 ;;
esac

# Exercise custom environment forwarding without requiring Apple container. Keep the
# fixture self-contained so config, credentials, caches, and env-files never touch the checkout.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aibox-smoke.XXXXXX")"
# macOS sets TMPDIR with a trailing slash, which leaves a // in every derived path, while the
# launcher normalizes directories with cd && pwd. Normalize once so the paths compare equal.
TMP_ROOT="$(cd "$TMP_ROOT" && pwd)"
# Keep the machine wrapper away from the profile of whatever machine runs these tests.
export AIBOX_DEV_PROFILE="$TMP_ROOT/no-machine-profile"
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
STUB_BUILD_CONTEXT="$TMP_ROOT/container.build-context"
STUB_LS_RUNNING=""
STUB_LS_ALL=""
STUB_MACHINE_LIST=""
STUB_MACHINE_LIST_FAIL=0
STUB_IMAGE_PRESENT=1
STUB_MACHINE_INSPECT_JSON='[{"cpus":6,"createdDate":"2026-08-16T15:22:49Z","diskSize":2691284992,"homeMount":"rw","id":"aibox-dev","image":{"reference":"ai-sandbox-dev:latest"},"ipAddress":"192.168.65.5","memory":8589934592,"platform":{"architecture":"arm64","os":"linux"},"startedDate":"2026-08-16T15:22:50Z","status":"running","userSetup":{"gid":20,"uid":501,"username":"developer"}}]'
STUB_MACHINE_INSPECT_FAIL=0
STUB_DEV_SYSTEMD_FAIL=0
STUB_MACHINE_HOME=""
STUB_MACHINE_BUSY=""
STUB_CONTAINER_VERSION="1.6.0"
ORIGINAL_PATH="$PATH"
HOST_STUB_PATH="$STUB_BIN:$ORIGINAL_PATH"

mkdir -p "$FIXTURE" "$STUB_BIN" "$TEST_HOME" "$RUN_TMP" "$PROJECT"
cp "$ROOT/ai-box" "$ROOT/aibox-ui.sh" "$ROOT/Dockerfile" "$ROOT/Dockerfile.dev" "$ROOT/Dockerfile.update" \
    "$ROOT/.dockerignore" "$ROOT/entrypoint.sh" "$ROOT/network-lockdown.sh" "$ROOT/user-exec.sh" \
    "$ROOT/enter-shell.sh" "$ROOT/dev-profile.sh" "$ROOT/dev-shell.sh" "$ROOT/dev-configure.sh" \
    "$ROOT/dev-proxy-run.sh" "$ROOT/dev-tools.sh" "$ROOT/aibox-dev-proxy.service" "$FIXTURE/"
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

if [ "${1:-}" = "build" ]; then
    # Record what the staged build context contains; the launcher runs build inside it.
    find . -type f | sort > "$STUB_BUILD_CONTEXT"
fi

if [ "${1:-}" = "--version" ]; then
    echo "container CLI version ${STUB_CONTAINER_VERSION:-1.6.0} (build: release, commit: stub)"
    exit 0
fi

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

# Simulate the few in-machine commands the legacy migration uses. STUB_MACHINE_HOME stands
# for the machine user's own home (/home/dev); empty means the machine has no such data.
stub_machine_cmd() {
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --name|--env-file|--workdir|-w|-u|--user) shift 2 ;;
            --root|--interactive|--tty|-i|-t) shift ;;
            *) break ;;
        esac
    done
    case "${1:-}" in
        printenv)
            [ -z "${STUB_MACHINE_HOME:-}" ] || echo /home/dev
            return 0
            ;;
        pgrep)
            [ -n "${STUB_MACHINE_BUSY:-}" ]
            return $?
            ;;
        ls|cp|mv|ln|test|tar)
            [ -n "${STUB_MACHINE_HOME:-}" ] || return 2
            stub_cmd="$1"
            shift
            stub_mapped=()
            for arg in "$@"; do
                stub_mapped+=("${arg//\/home\/dev/$STUB_MACHINE_HOME}")
            done
            if [ "$stub_cmd" = tar ] && [ -f "$STUB_MACHINE_HOME/fail-archive" ]; then
                # A readable archive followed by failure must still abort migration.
                "$stub_cmd" "${stub_mapped[@]}"
                return 1
            fi
            "$stub_cmd" "${stub_mapped[@]}"
            return $?
            ;;
    esac
    return 99
}
if [ "${1:-}" = "machine" ] && [ "${2:-}" = "run" ]; then
    stub_rc=0
    stub_machine_cmd "$@" || stub_rc=$?
    [ "$stub_rc" -eq 99 ] || exit "$stub_rc"
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
cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/sh
printf '{"name":"stub","version":"9.9.9"}\n'
STUB
# The clipboard bridge status asks launchd whether the watcher is loaded. Answer "not
# loaded" so the real host's watcher (if any) never leaks into the results.
cat > "$STUB_BIN/launchctl" <<'STUB'
#!/bin/sh
[ "${1:-}" != "print" ]
STUB
# aibox only runs on macOS; pretend to be one unless a test asks otherwise.
cat > "$STUB_BIN/uname" <<'STUB'
#!/bin/sh
case "${1:-}" in
    -m) echo arm64 ;;
    *)  echo "${STUB_UNAME:-Darwin}" ;;
esac
STUB
chmod +x "$STUB_BIN/container" "$STUB_BIN/curl" "$STUB_BIN/launchctl" "$STUB_BIN/uname" \
    "$FIXTURE/ai-box" "$FIXTURE/entrypoint.sh"

fail() {
    echo "smoke test failed: $1" >&2
    exit 1
}

file_mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
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
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL STUB_MACHINE_HOME STUB_MACHINE_BUSY STUB_CONTAINER_VERSION STUB_BUILD_CONTEXT
    export ANTHROPIC_API_KEY="host-anthropic-key-must-not-be-forwarded"
    unset OPENAI_API_KEY AIBOX_PROXY AIBOX_TZ AIBOX_LANG AIBOX_MEMORY AIBOX_CPUS
    [ -z "${FIXTURE_MEMORY:-}" ] || export AIBOX_MEMORY="$FIXTURE_MEMORY"
    unset FIXED_SOCKS_HOST FIXED_SOCKS_PORT FIXED_SOCKS_USER FIXED_SOCKS_PASS
    "$FIXTURE/ai-box" tmp "$PROJECT"
)

run_fixture_command() (
    export HOME="$TEST_HOME"
    export PATH="$HOST_STUB_PATH"
    export TMPDIR="$RUN_TMP"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export STUB_CALLS STUB_ENV_LOG STUB_LS_RUNNING STUB_LS_ALL STUB_MACHINE_LIST STUB_MACHINE_LIST_FAIL STUB_IMAGE_PRESENT
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL STUB_MACHINE_HOME STUB_MACHINE_BUSY STUB_CONTAINER_VERSION STUB_BUILD_CONTEXT
    unset AIBOX_PROXY AIBOX_TZ AIBOX_LANG AIBOX_MEMORY AIBOX_CPUS
    unset FIXED_SOCKS_HOST FIXED_SOCKS_PORT FIXED_SOCKS_USER FIXED_SOCKS_PASS
    "$FIXTURE/ai-box" "$@"
)

# Most cases run as an already-migrated install; the legacy-migration cases below
# remove this marker explicitly.
mkdir -p "$TEST_HOME/.aibox"
printf 'choice=test\n' > "$TEST_HOME/.aibox/.migrated"

# An explicitly empty indexed array must work under macOS Bash 3.2 + set -u and must
# not create or mount an env-file.
cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
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
assert_arg_pair -v "$TEST_HOME/.aibox/claude:/home/node/.claude"
assert_arg_pair -v "$TEST_HOME/.aibox/codex:/home/node/.codex"
assert_file_omits "$STUB_ARGS" "$FIXTURE/creds" \
    "ephemeral container still mounted credentials from the checkout"

# Legacy login state lives in two places: the checkout's creds/ (temporary containers) and
# the machine user's own ~/.claude (persistent container). The first launch copies it into
# ~/.aibox; with both present the user picks one or merges. Old data is never deleted: the
# machine's directories are renamed and replaced by links to ~/.aibox, creds/ moves to
# ~/.aibox/legacy/.
MACHINE_HOME_DIR="$TMP_ROOT/machine-home"
LEGACY_DST="$TEST_HOME/.aibox"
reset_legacy() {
    rm -rf "$LEGACY_DST" "$FIXTURE/creds" "$MACHINE_HOME_DIR"
    mkdir -p "$FIXTURE/creds/claude/projects/-workspace-proj" "$FIXTURE/creds/codex"
    printf 'tmp-md\n' > "$FIXTURE/creds/claude/CLAUDE.md"
    printf 'tmp-only\n' > "$FIXTURE/creds/claude/tmp-only"
    printf 'tmp-session\n' > "$FIXTURE/creds/claude/projects/-workspace-proj/s.jsonl"
    printf 'tmp-codex\n' > "$FIXTURE/creds/codex/auth.json"
    mkdir -p "$MACHINE_HOME_DIR/.claude/projects/-Users-dev-proj"
    printf 'machine-md\n' > "$MACHINE_HOME_DIR/.claude/CLAUDE.md"
    printf 'machine-session\n' > "$MACHINE_HOME_DIR/.claude/projects/-Users-dev-proj/s.jsonl"
}

# Only the checkout has legacy data and there is no machine: copied without asking.
reset_legacy
STUB_MACHINE_LIST=""
STUB_MACHINE_HOME=""
reset_stub_files
run_fixture < /dev/null > "$TMP_ROOT/migrate-tmp-only.output" 2>&1 \
    || fail "launch with legacy checkout state failed"
assert_file_has_line "$LEGACY_DST/claude/CLAUDE.md" 'tmp-md' \
    "legacy checkout Claude state was not copied into ~/.aibox"
assert_file_has_line "$LEGACY_DST/codex/auth.json" 'tmp-codex' \
    "legacy checkout Codex state was not copied into ~/.aibox"
[ ! -e "$FIXTURE/creds" ] || fail "migrated checkout state was left in the checkout"
legacy_backup="$(ls -d "$LEGACY_DST"/legacy/creds-*/claude/CLAUDE.md 2>/dev/null | head -n 1)"
[ -n "$legacy_backup" ] || fail "migration did not keep a backup of the checkout state"
[ -f "$LEGACY_DST/.migrated" ] || fail "migration did not record completion"
mkdir -p "$FIXTURE/creds/claude"
printf 'changed\n' > "$FIXTURE/creds/claude/CLAUDE.md"
reset_stub_files
run_fixture < /dev/null > "$TMP_ROOT/migrate-again.output" 2>&1 \
    || fail "launch after a completed migration failed"
assert_file_has_line "$LEGACY_DST/claude/CLAUDE.md" 'tmp-md' \
    "a completed migration ran again"

# Both sources, default answer: merge with the persistent container's state as the base.
reset_legacy
STUB_MACHINE_LIST="aibox-dev"
STUB_MACHINE_HOME="$MACHINE_HOME_DIR"
reset_stub_files
printf '\n' | run_fixture > "$TMP_ROOT/migrate-merge.output" 2>&1 \
    || fail "merging legacy state failed"
assert_file_has_line "$LEGACY_DST/claude/CLAUDE.md" 'machine-md' \
    "merge did not keep the persistent container's file as the base"
assert_file_has_line "$LEGACY_DST/claude/CLAUDE.md.from-tmp" 'tmp-md' \
    "merge did not set the conflicting temporary-container file aside"
assert_file_has_line "$LEGACY_DST/claude/projects/-Users-dev-proj/s.jsonl" 'machine-session' \
    "merge lost the persistent container's sessions"
assert_file_has_line "$LEGACY_DST/claude/projects/-workspace-proj/s.jsonl" 'tmp-session' \
    "merge lost the temporary container's sessions"
assert_file_has_line "$LEGACY_DST/claude/tmp-only" 'tmp-only' \
    "merge dropped a file that only the temporary container had"
assert_file_has_line "$LEGACY_DST/codex/auth.json" 'tmp-codex' \
    "Codex state that only the temporary container had was not copied"
assert_file_contains "$TMP_ROOT/migrate-merge.output" 'CLAUDE.md.from-tmp' \
    "merge did not report the conflicting file"
[ -L "$MACHINE_HOME_DIR/.claude" ] || fail "the machine's old ~/.claude was not replaced by a link"
[ "$(readlink "$MACHINE_HOME_DIR/.claude")" = "$LEGACY_DST/claude" ] \
    || fail "the machine's ~/.claude link does not point at ~/.aibox/claude"
machine_backup="$(ls -d "$MACHINE_HOME_DIR"/.claude.pre-aibox-*/CLAUDE.md 2>/dev/null | head -n 1)"
[ -n "$machine_backup" ] || fail "the machine's old ~/.claude was not kept as a backup"
assert_file_has_line "$machine_backup" 'machine-md' "the machine backup lost its content"
[ ! -e "$MACHINE_HOME_DIR/.codex" ] || fail "migration invented a machine ~/.codex it never had"
[ ! -e "$FIXTURE/creds" ] || fail "merged checkout state was left in the checkout"

# Choosing one source copies only that one (falling back to the other per tool).
reset_legacy
reset_stub_files
printf '1\n' | run_fixture > "$TMP_ROOT/migrate-machine.output" 2>&1 \
    || fail "choosing the persistent container's state failed"
assert_file_has_line "$LEGACY_DST/claude/CLAUDE.md" 'machine-md' \
    "choice 1 did not use the persistent container's state"
[ ! -e "$LEGACY_DST/claude/tmp-only" ] || fail "choice 1 mixed in the temporary container's files"
assert_file_has_line "$LEGACY_DST/codex/auth.json" 'tmp-codex' \
    "choice 1 did not fall back for a tool the machine never used"
reset_legacy
reset_stub_files
printf '2\n' | run_fixture > "$TMP_ROOT/migrate-tmp.output" 2>&1 \
    || fail "choosing the temporary container's state failed"
assert_file_has_line "$LEGACY_DST/claude/CLAUDE.md" 'tmp-md' \
    "choice 2 did not use the temporary container's state"
[ ! -e "$LEGACY_DST/claude/projects/-Users-dev-proj" ] \
    || fail "choice 2 mixed in the persistent container's files"
[ -L "$MACHINE_HOME_DIR/.claude" ] \
    || fail "choice 2 left the unused machine ~/.claude where non-login entry points still use it"

# Codex daemon sockets cannot be copied to the host share. Skip the runtime endpoint,
# retain credentials (including hidden files and links), and keep the original backup.
reset_legacy
mkdir -p "$MACHINE_HOME_DIR/.codex/app-server-daemon"
printf 'machine-codex\n' > "$MACHINE_HOME_DIR/.codex/auth.json"
printf 'hidden\n' > "$MACHINE_HOME_DIR/.codex/.hidden"
ln -s auth.json "$MACHINE_HOME_DIR/.codex/auth-link"
python3 - "$MACHINE_HOME_DIR/.codex/app-server-daemon/daemon-updater.sock" <<'PY'
import os
import socket
import sys
os.chdir(os.path.dirname(sys.argv[1]))
with socket.socket(socket.AF_UNIX) as endpoint:
    endpoint.bind(os.path.basename(sys.argv[1]))
PY
reset_stub_files
printf '1\n' | run_fixture > "$TMP_ROOT/migrate-socket.output" 2>&1 \
    || fail "migration failed on a Codex daemon socket"
assert_file_has_line "$LEGACY_DST/codex/auth.json" 'machine-codex' \
    "socket migration lost Codex credentials"
assert_file_has_line "$LEGACY_DST/codex/.hidden" 'hidden' \
    "socket migration lost a hidden file"
[ "$(readlink "$LEGACY_DST/codex/auth-link")" = auth.json ] \
    || fail "socket migration lost a symbolic link"
[ ! -e "$LEGACY_DST/codex/app-server-daemon/daemon-updater.sock" ] \
    || fail "migration copied a runtime socket"
[ -S "$MACHINE_HOME_DIR"/.codex.pre-aibox-*/app-server-daemon/daemon-updater.sock ] \
    || fail "migration did not retain the original socket in the backup"
[ -f "$LEGACY_DST/.migrated" ] || fail "socket migration did not complete"

# An archive producer failure must not be masked by successful extraction.
reset_legacy
touch "$MACHINE_HOME_DIR/fail-archive"
reset_stub_files
if printf '1\n' | run_fixture > "$TMP_ROOT/migrate-archive-fail.output" 2>&1; then
    fail "migration ignored an archive producer failure"
fi
[ ! -f "$LEGACY_DST/.migrated" ] || fail "failed copying recorded completion"
[ ! -L "$MACHINE_HOME_DIR/.claude" ] || fail "failed copying replaced the source"
[ -d "$FIXTURE/creds" ] || fail "failed copying moved the checkout source"
rm "$MACHINE_HOME_DIR/fail-archive"
reset_stub_files
printf '1\n' | run_fixture > "$TMP_ROOT/migrate-archive-retry.output" 2>&1 \
    || fail "retrying an interrupted migration failed"
[ -f "$LEGACY_DST/.migrated" ] || fail "retried migration did not complete"

# Running Claude/Codex in the machine (or old temporary containers) would keep writing to the
# old locations, so the migration warns and only proceeds on an explicit yes.
reset_legacy
STUB_MACHINE_BUSY=1
reset_stub_files
if printf 'n\n' | run_fixture > "$TMP_ROOT/migrate-busy.output" 2>&1; then
    fail "migration proceeded while Claude was still running in the machine"
fi
assert_file_contains "$TMP_ROOT/migrate-busy.output" 'Claude Code' \
    "the busy warning did not name the running tool"
[ ! -f "$LEGACY_DST/.migrated" ] || fail "a declined busy migration recorded completion"
[ ! -L "$MACHINE_HOME_DIR/.claude" ] || fail "a declined busy migration touched the machine's data"
reset_stub_files
printf 'y\n3\n' | run_fixture > "$TMP_ROOT/migrate-busy-yes.output" 2>&1 \
    || fail "confirming a busy migration failed"
[ -f "$LEGACY_DST/.migrated" ] || fail "a confirmed busy migration did not complete"
STUB_MACHINE_BUSY=""

# "Later" and a closed stdin both stop without starting anything or recording completion.
for later_input in '4' ''; do
    reset_legacy
    reset_stub_files
    if printf '%s' "$later_input" | run_fixture > "$TMP_ROOT/migrate-later.output" 2>&1; then
        fail "postponing the migration still launched a container"
    fi
    [ ! -f "$LEGACY_DST/.migrated" ] || fail "postponing the migration recorded completion"
    assert_file_omits "$STUB_CALLS" 'CALL run' "postponing the migration still ran a container"
done

# Content already in ~/.aibox is moved aside instead of being mixed with legacy data.
reset_legacy
mkdir -p "$LEGACY_DST/claude"
printf 'fresh-login\n' > "$LEGACY_DST/claude/existing"
reset_stub_files
printf '3\n' | run_fixture > "$TMP_ROOT/migrate-aside.output" 2>&1 \
    || fail "migrating over an existing ~/.aibox failed"
aside_file="$(ls -d "$LEGACY_DST"/claude.before-migrate-*/existing 2>/dev/null | head -n 1)"
[ -n "$aside_file" ] || fail "existing ~/.aibox content was not moved aside"
[ ! -e "$LEGACY_DST/claude/existing" ] || fail "existing ~/.aibox content was mixed with legacy data"

# aibox migrate runs the same flow explicitly and reports when it is already done.
reset_legacy
reset_stub_files
printf '3\n' | run_fixture_command migrate > "$TMP_ROOT/migrate-explicit.output" 2>&1 \
    || fail "aibox migrate failed"
[ -f "$LEGACY_DST/.migrated" ] || fail "aibox migrate did not record completion"
assert_file_contains "$STUB_CALLS" 'CALL machine run --name aibox-dev tar -cf - -C /home/dev/.claude .' \
    "aibox migrate did not copy the machine state from inside the machine"
rm -f "$LEGACY_DST/.migrated"
rm -rf "$FIXTURE/creds"
run_fixture_command migrate < /dev/null > "$TMP_ROOT/migrate-relink.output" 2>&1 \
    || fail "a machine whose ~/.claude is already a link was treated as legacy data"
run_fixture_command migrate > "$TMP_ROOT/migrate-done.output" 2>&1 \
    || fail "aibox migrate after completion failed"
assert_file_contains "$TMP_ROOT/migrate-done.output" '已经迁移过' \
    "aibox migrate did not report a completed migration"

rm -rf "$FIXTURE/creds" "$MACHINE_HOME_DIR" "$LEGACY_DST"
mkdir -p "$LEGACY_DST"
printf 'choice=test\n' > "$LEGACY_DST/.migrated"
STUB_MACHINE_LIST=""
STUB_MACHINE_HOME=""

# Without the ephemeral image the launcher must stop before container run, which would
# otherwise try to pull a same-named image from Docker Hub, and point at the setup wizard.
reset_stub_files
STUB_IMAGE_PRESENT=0
if run_fixture > "$TMP_ROOT/no-image.output" 2>&1; then
    fail "launch without the ephemeral image unexpectedly succeeded"
fi
STUB_IMAGE_PRESENT=1
assert_file_contains "$TMP_ROOT/no-image.output" 'aibox build' \
    "missing-image error does not say how to build the image"
assert_file_contains "$TMP_ROOT/no-image.output" 'aibox setup' \
    "missing-image error does not point to the setup wizard"
assert_file_omits "$STUB_CALLS" 'CALL run' \
    "launcher called container run without the ephemeral image"

# Values live only in the temporary env-file. PATH and HOME are intentionally included
# to prove they do not alter how the host-side launcher finds the container stub or caches.
cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
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
cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
AIBOX_PROXY="socks5h://proxy.example.invalid:1080"
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_ENV_VARS=()
CONF
reset_stub_files
run_fixture > "$TMP_ROOT/proxy.output" 2>&1 || fail "proxy-mode launch failed"
assert_arg_pair --cap-add CAP_NET_ADMIN
assert_arg_pair --label 'com.simpletang.ai-sandbox.managed=true'

# Resources: 8192M and the container's own CPU default unless aibox.conf says otherwise.
# Build caches (Maven / Gradle) are no longer mounted.
assert_arg_pair --memory 8192M
assert_file_omits "$STUB_ARGS" '--cpus' "a launch without AIBOX_CPUS passed --cpus"
assert_file_omits "$STUB_ARGS" '/.m2' "the temporary container still mounts a Maven cache"
assert_file_omits "$STUB_ARGS" '/.gradle' "the temporary container still mounts a Gradle cache"
cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
AIBOX_PROXY=""
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_MEMORY="16g"
AIBOX_CPUS="6"
AIBOX_ENV_VARS=()
CONF
reset_stub_files
run_fixture > "$TMP_ROOT/resources.output" 2>&1 || fail "launch with configured resources failed"
assert_arg_pair --memory 16G
assert_arg_pair --cpus 6
reset_stub_files
FIXTURE_MEMORY=4G run_fixture > "$TMP_ROOT/resources-env.output" 2>&1 \
    || fail "launch with AIBOX_MEMORY from the environment failed"
assert_arg_pair --memory 4G
for bad_resource in 'AIBOX_MEMORY="8"' 'AIBOX_MEMORY="8GB"' 'AIBOX_CPUS="0"' 'AIBOX_CPUS="two"'; do
    printf 'AIBOX_TZ="UTC"\n%s\n' "$bad_resource" > "$TEST_HOME/.aibox/aibox.conf"
    reset_stub_files
    if run_fixture > "$TMP_ROOT/resources-bad.output" 2>&1; then
        fail "an invalid resource setting was accepted: $bad_resource"
    fi
    assert_file_contains "$TMP_ROOT/resources-bad.output" '格式不对' \
        "an invalid resource setting was not explained: $bad_resource"
    [ ! -e "$STUB_ARGS" ] || fail "an invalid resource setting still started a container: $bad_resource"
done
cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
AIBOX_PROXY="socks5h://proxy.example.invalid:1080"
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_ENV_VARS=()
CONF

# Legacy ai-* and other names must never enter the managed container list.
STUB_LS_RUNNING="aibox-alpha-project-120000-101
ai-legacy-project-120000
unrelated-container"
STUB_LS_ALL="$STUB_LS_RUNNING"
run_fixture_command tmp list > "$TMP_ROOT/list.output" 2>&1 || fail "managed list failed"
assert_file_contains "$TMP_ROOT/list.output" 'aibox-alpha-project-120000-101' \
    "managed aibox container was omitted from list"
assert_file_omits "$TMP_ROOT/list.output" 'ai-legacy-project-120000' \
    "legacy ai-* container leaked into managed list"
assert_file_omits "$TMP_ROOT/list.output" 'unrelated-container' \
    "unrelated container leaked into managed list"

reset_stub_files
STUB_LS_RUNNING="aibox-alpha-project-120000-101"
run_fixture_command tmp enter 1 > "$TMP_ROOT/enter.output" 2>&1 \
    || fail "entering a managed container failed"
assert_arg_pair -u root
assert_arg_pair -w '/workspace/alpha-project'
assert_file_contains "$STUB_ARGS" '/usr/local/sbin/aibox-enter-shell' \
    "enter did not use the trusted privilege-drop helper"

# Without a target, enter offers a menu of the running containers (item numbers outside a
# terminal); end of input cancels instead of picking one.
reset_stub_files
STUB_LS_RUNNING="aibox-alpha-project-120000-101
aibox-beta-project-120500-202"
printf '2\n' | run_fixture_command tmp enter > "$TMP_ROOT/enter-menu.output" 2>&1 \
    || fail "choosing a container from the enter menu failed"
assert_file_contains "$TMP_ROOT/enter-menu.output" 'beta-project' \
    "the enter menu did not list the running containers"
assert_arg_pair -w '/workspace/beta-project'
reset_stub_files
if run_fixture_command tmp enter < /dev/null > "$TMP_ROOT/enter-eof.output" 2>&1; then
    fail "enter without input should cancel"
fi
[ ! -s "$STUB_ARGS" ] || fail "enter without input still entered a container"
STUB_LS_RUNNING=""
STUB_LS_ALL=""

# The persistent development machine is created once, then machine run handles both
# booting a stopped machine and opening its login shell.
cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
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
run_fixture_command > "$TMP_ROOT/dev-create.output" 2>&1 \
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
case "$root_env_block" in
    *"AIBOX_STATE_DIR=$TEST_HOME/.aibox"*) ;;
    *) fail "dev root configuration did not receive the host-side ~/.aibox path" ;;
esac
case "$root_env_block" in
    *"AIBOX_HOST_UID="*) ;;
    *) fail "dev root configuration did not receive the host UID" ;;
esac
case "$root_env_block" in
    *'ln -s "$AIBOX_STATE_DIR/$name"'*) ;;
    *) fail "dev root configuration does not link the machine user's ~/.claude to ~/.aibox" ;;
esac
assert_file_omits "$STUB_ENV_COPY" 'AIBOX_DEV_LAUNCH=' \
    "a plain aibox shell asked the machine to launch a tool"
assert_file_has_line "$STUB_ENV_MODE" '600' "dev env-file permissions were not 0600"
dev_env_file_path="$(sed -n '1p' "$STUB_ENV_PATH")"
[ ! -e "$dev_env_file_path" ] || fail "dev launcher did not remove its env-file"
if find "$RUN_TMP" -type f \( -name 'aibox-dev-env.*' -o -name 'aibox-dev-system.*' \) | grep -q .; then
    fail "dev launcher left a temporary environment file"
fi

# Configured resources apply when the machine is first created.
cp "$TEST_HOME/.aibox/aibox.conf" "$TMP_ROOT/dev-conf.saved"
printf 'AIBOX_MEMORY="12G"\nAIBOX_CPUS="3"\n' >> "$TEST_HOME/.aibox/aibox.conf"
reset_stub_files
STUB_MACHINE_LIST=""
run_fixture_command > "$TMP_ROOT/dev-create-resources.output" 2>&1 \
    || fail "creating the persistent machine with configured resources failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine create --name aibox-dev --memory 12G --cpus 3 --home-mount rw ai-sandbox-dev:latest' \
    "the persistent machine was not created with the configured resources"
mv "$TMP_ROOT/dev-conf.saved" "$TEST_HOME/.aibox/aibox.conf"

reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
run_fixture_command > "$TMP_ROOT/dev-existing.output" 2>&1 \
    || fail "existing persistent development-machine launch failed"
assert_file_omits "$STUB_CALLS" 'CALL machine create' \
    "existing persistent machine was recreated"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --interactive --tty --name aibox-dev' \
    "existing persistent machine was not entered"

reset_stub_files
run_fixture_command start > "$TMP_ROOT/dev-start.output" 2>&1 \
    || fail "starting the persistent machine without a shell failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev --root --env-file' \
    "dev start did not apply machine configuration"
assert_file_omits "$STUB_CALLS" 'CALL machine run --interactive' \
    "dev start unexpectedly opened a login shell"

reset_stub_files
STUB_DEV_SYSTEMD_FAIL=1
if run_fixture_command start > "$TMP_ROOT/dev-systemd-timeout.output" 2>&1; then
    fail "dev start ignored a systemd readiness timeout"
fi
assert_file_contains "$TMP_ROOT/dev-systemd-timeout.output" \
    '长期容器启动后 systemd 未能在 30 秒内就绪' \
    "dev start did not explain its systemd readiness failure"
assert_file_omits "$STUB_CALLS" '/usr/local/sbin/aibox-dev-configure' \
    "dev configured the machine after systemd readiness failed"
assert_file_omits "$STUB_CALLS" '/usr/local/bin/aibox-dev-shell' \
    "dev opened a login shell after systemd readiness failed"
STUB_DEV_SYSTEMD_FAIL=0

reset_stub_files
run_fixture_command restart > "$TMP_ROOT/dev-restart.output" 2>&1 \
    || fail "restarting the persistent machine failed"
assert_file_contains "$STUB_CALLS" 'CALL machine stop aibox-dev' \
    "dev restart did not stop the machine first"
assert_file_contains "$STUB_CALLS" '/usr/local/sbin/aibox-dev-configure' \
    "dev restart did not reapply machine configuration"

# container machine run re-splits plain arguments on spaces, so exec passes the command
# shell-quoted through the env-file and the machine wrapper restores it verbatim.
reset_stub_files
run_fixture_command exec printf '%s|' 'two words' "it's" > "$TMP_ROOT/dev-exec.output" 2>&1 \
    || fail "executing a command in the persistent machine failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --interactive --tty --name aibox-dev' \
    "dev exec did not allocate an interactive machine process"
assert_file_contains "$STUB_CALLS" '/usr/local/bin/aibox-dev-shell' \
    "dev exec did not run through the environment wrapper"
assert_file_omits "$STUB_CALLS" 'two words' \
    "dev exec passed its arguments on the machine run command line"
dev_exec_value="$(sed -n 's/^AIBOX_DEV_EXEC=//p' "$STUB_ENV_COPY")"
[ -n "$dev_exec_value" ] || fail "dev exec did not pass its command through the env-file"
AIBOX_DEV_EXEC="$dev_exec_value" /bin/bash "$ROOT/dev-shell.sh" > "$TMP_ROOT/dev-exec.result" 2>&1 \
    || fail "the machine wrapper could not run the quoted exec command"
[ "$(cat "$TMP_ROOT/dev-exec.result")" = "two words|it's|" ] \
    || fail "dev exec did not preserve arguments with spaces and quotes"

reset_stub_files
printf 'n\n' | run_fixture_command update cc > "$TMP_ROOT/dev-update-cancel.output" 2>&1 \
    || fail "cancelling a persistent machine update failed"
assert_file_contains "$TMP_ROOT/dev-update-cancel.output" '9.9.9' \
    "update did not show the available version before asking"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev /usr/local/sbin/aibox-dev-tools version claude' \
    "update did not read the installed version first"
assert_file_omits "$STUB_CALLS" 'aibox-dev-tools update' \
    "update installed packages without confirmation"

reset_stub_files
printf 'y\n' | run_fixture_command update cc > "$TMP_ROOT/dev-update.output" 2>&1 \
    || fail "updating Claude in the persistent machine failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev --root /usr/local/sbin/aibox-dev-tools update claude' \
    "dev update did not target the machine-local Claude installation"

reset_stub_files
run_fixture_command version codex > "$TMP_ROOT/dev-version.output" 2>&1 \
    || fail "reading the persistent machine Codex version failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine run --name aibox-dev /usr/local/sbin/aibox-dev-tools version codex' \
    "dev version did not inspect the machine-local Codex installation"

reset_stub_files
run_fixture_command set memory=12G cpus=6 > "$TMP_ROOT/dev-set.output" 2>&1 \
    || fail "setting persistent machine resources failed"
assert_file_contains "$STUB_CALLS" \
    'CALL machine set --name aibox-dev memory=12G cpus=6' \
    "dev set did not forward validated machine resources"

reset_stub_files
if run_fixture_command set home-mount=none > "$TMP_ROOT/dev-set-invalid.output" 2>&1; then
    fail "dev set accepted a setting outside the aibox resource contract"
fi
assert_file_omits "$STUB_CALLS" 'CALL machine set' \
    "invalid dev set reached the container CLI"

reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
STUB_MACHINE_INSPECT_FAIL=0
run_fixture_command status > "$TMP_ROOT/dev-status.output" 2>&1 \
    || fail "reading the persistent machine status failed"
assert_file_contains "$TMP_ROOT/dev-status.output" '1.6.0(已验证 1.6.0)' \
    "status did not report the Apple container version against the verified one"
assert_file_contains "$TMP_ROOT/dev-status.output" '== 长期容器 ==' \
    "dev status is missing its readable heading"
# Field extraction uses macOS plutil, which Linux runners do not have; the launcher only
# runs on macOS anyway.
if [ "$(uname -s)" = Darwin ]; then
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
fi
assert_file_omits "$TMP_ROOT/dev-status.output" '[{"cpus"' \
    "dev status leaked raw inspect JSON"
assert_file_contains "$TMP_ROOT/dev-status.output" '资源配置   : 内存 8192M / CPU 默认' \
    "status did not show the configured container resources"

reset_stub_files
STUB_MACHINE_INSPECT_FAIL=1
if run_fixture_command status > "$TMP_ROOT/dev-status-inspect-error.output" 2>&1; then
    fail "dev status treated an inspect failure as success"
fi
assert_file_contains "$TMP_ROOT/dev-status-inspect-error.output" 'machine inspect unavailable' \
    "dev status hid the machine inspect failure"
STUB_MACHINE_INSPECT_FAIL=0

reset_stub_files
STUB_MACHINE_LIST_FAIL=1
if run_fixture_command status > "$TMP_ROOT/dev-status-error.output" 2>&1; then
    fail "dev status treated a machine query failure as success"
fi
assert_file_contains "$TMP_ROOT/dev-status-error.output" 'machine service unavailable' \
    "dev status hid the machine query failure"
assert_file_omits "$TMP_ROOT/dev-status-error.output" '尚未创建' \
    "dev status misreported a query failure as a missing machine"
STUB_MACHINE_LIST_FAIL=0

reset_stub_files
run_fixture_command stop > "$TMP_ROOT/dev-stop.output" 2>&1 \
    || fail "stopping the persistent development machine failed"
assert_file_contains "$STUB_CALLS" 'CALL machine stop aibox-dev' \
    "dev stop did not target the persistent machine"
assert_file_omits "$STUB_CALLS" 'CALL machine delete' \
    "dev stop deleted persistent storage"

reset_stub_files
printf 'n\n' | run_fixture_command delete > "$TMP_ROOT/dev-delete-cancel.output" 2>&1 \
    || fail "cancelling persistent machine deletion failed"
assert_file_omits "$STUB_CALLS" 'CALL machine delete' \
    "dev delete ignored a negative confirmation"

reset_stub_files
printf 'y\n' | run_fixture_command delete > "$TMP_ROOT/dev-delete.output" 2>&1 \
    || fail "deleting the persistent development machine failed"
assert_file_contains "$STUB_CALLS" 'CALL machine delete aibox-dev' \
    "confirmed dev delete did not target the persistent machine"

reset_stub_files
STUB_MACHINE_LIST=""
STUB_IMAGE_PRESENT=0
if run_fixture_command > "$TMP_ROOT/dev-missing-image.output" 2>&1; then
    fail "dev unexpectedly launched without its machine image"
fi
assert_file_contains "$TMP_ROOT/dev-missing-image.output" 'aibox build' \
    "missing development-machine image error did not explain how to build it"
assert_file_omits "$STUB_CALLS" 'CALL machine create' \
    "dev attempted machine creation without its image"

reset_stub_files
STUB_IMAGE_PRESENT=1
run_fixture_command tmp build --no-cache > "$TMP_ROOT/build.output" 2>&1 \
    || fail "ephemeral image build command failed"
assert_file_contains "$STUB_CALLS" 'CALL build --build-arg CLAUDE_CODE_VERSION=' \
    "tmp build did not pass the CLI versions"
assert_file_contains "$STUB_CALLS" ' --no-cache -t ai-sandbox:latest .' \
    "tmp build omitted the ephemeral image or the user's arguments"
assert_file_omits "$STUB_CALLS" 'Dockerfile.dev' \
    "tmp build unexpectedly rebuilt the persistent machine image"

reset_stub_files
run_fixture_command build --no-cache > "$TMP_ROOT/dev-build.output" 2>&1 \
    || fail "image build command failed"
assert_file_contains "$STUB_CALLS" ' -t ai-sandbox:latest .' \
    "build omitted the base image"
assert_file_contains "$STUB_CALLS" \
    'CALL build --no-cache -f Dockerfile.dev --build-arg BASE_IMAGE=ai-sandbox:latest -t ai-sandbox-dev:latest .' \
    "build omitted the persistent machine image"
base_build_line="$(grep -n -m 1 ' -t ai-sandbox:latest' "$STUB_CALLS" | cut -d: -f1)"
dev_build_line="$(grep -n -m 1 'Dockerfile.dev' "$STUB_CALLS" | cut -d: -f1)"
(( base_build_line < dev_build_line )) || fail "build did not build the base image first"
STUB_IMAGE_PRESENT=1
STUB_MACHINE_LIST=""

# The persistent machine is the default now: cc starts Claude in the requested directory,
# a directory outside the mounted home is refused with a pointer to tmp, and the old
# dev/list spellings explain where the commands went.
mkdir -p "$TEST_HOME/work/proj"
STUB_MACHINE_LIST="aibox-dev"
reset_stub_files
run_fixture_command cc "$TEST_HOME/work/proj" > "$TMP_ROOT/dev-cc.output" 2>&1 \
    || fail "aibox cc in the persistent machine failed"
dev_cc_dir="$(cd -P "$TEST_HOME/work/proj" && pwd)"
assert_file_contains "$STUB_CALLS" "--workdir $dev_cc_dir /usr/local/bin/aibox-dev-shell" \
    "aibox cc did not open the requested directory"
assert_file_has_line "$STUB_ENV_COPY" 'AIBOX_DEV_LAUNCH=claude' \
    "aibox cc did not ask the machine shell to start Claude"
reset_stub_files
if run_fixture_command cc "$PROJECT" > "$TMP_ROOT/dev-cc-outside.output" 2>&1; then
    fail "aibox cc accepted a directory outside the mounted home"
fi
assert_file_contains "$TMP_ROOT/dev-cc-outside.output" 'aibox tmp cc' \
    "outside-home error did not suggest the ephemeral container"
[ ! -e "$STUB_CALLED" ] || fail "outside-home launch still reached the machine"
for removed_cmd in dev list; do
    if run_fixture_command "$removed_cmd" > "$TMP_ROOT/removed-$removed_cmd.output" 2>&1; then
        fail "aibox $removed_cmd unexpectedly succeeded"
    fi
    assert_file_contains "$TMP_ROOT/removed-$removed_cmd.output" 'aibox tmp' \
        "aibox $removed_cmd did not point at the tmp commands"
done
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

cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
AIBOX_ENV_VARS=(
    'BAD-NAME=invalid-name-value-must-stay-secret'
)
CONF
assert_rejected_before_container invalid-name 'invalid-name-value-must-stay-secret'

cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
AIBOX_ENV_VARS=(
    'AIBOX_PRIVATE=reserved-name-value-must-stay-secret'
)
CONF
assert_rejected_before_container reserved-name 'reserved-name-value-must-stay-secret'

cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
AIBOX_ENV_VARS=(
    $'CR_VALUE=cr-value-must-stay-secret\rsecond-line'
)
CONF
assert_rejected_before_container carriage-return 'cr-value-must-stay-secret'

cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
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
# The machine user's $HOME is on the machine's own disk, so the profile must use the
# host-side ~/.aibox path the launcher records in /etc/aibox/state-dir.
grep -qF '/etc/aibox/state-dir' "$ROOT/dev-profile.sh" \
    || fail "the persistent machine profile ignores the host-side ~/.aibox path"
grep -qxF 'export CLAUDE_CONFIG_DIR="$aibox_state_dir/claude"' "$ROOT/dev-profile.sh" \
    || fail "the persistent machine does not keep Claude state in ~/.aibox"
grep -qxF 'export CODEX_HOME="$aibox_state_dir/codex"' "$ROOT/dev-profile.sh" \
    || fail "the persistent machine does not keep Codex state in ~/.aibox"
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

# aibox cc in the machine: the wrapper starts the tool with the prepared environment,
# then falls back to a login shell (which exits here because stdin is empty).
DEV_LAUNCH_BIN="$TMP_ROOT/dev-launch-bin"
mkdir -p "$DEV_LAUNCH_BIN"
cat > "$DEV_LAUNCH_BIN/claude" <<'STUB'
#!/bin/sh
printf 'launched TZ=%s AIBOX_DEV_LAUNCH=%s\n' "$TZ" "${AIBOX_DEV_LAUNCH:-}" > "$DEV_LAUNCH_MARK"
exit 3
STUB
chmod +x "$DEV_LAUNCH_BIN/claude"
DEV_LAUNCH_MARK="$TMP_ROOT/dev-launch.mark"
PATH="$DEV_LAUNCH_BIN:/usr/bin:/bin" DEV_LAUNCH_MARK="$DEV_LAUNCH_MARK" \
AIBOX_TZ="UTC" AIBOX_DEV_LAUNCH="claude" \
    /bin/bash "$ROOT/dev-shell.sh" < /dev/null > "$TMP_ROOT/dev-launch.output" 2>&1 \
    || fail "the machine wrapper did not fall back to a shell after the tool exited"
assert_file_has_line "$DEV_LAUNCH_MARK" 'launched TZ=UTC AIBOX_DEV_LAUNCH=' \
    "the machine wrapper did not start Claude with the prepared environment"
if AIBOX_DEV_LAUNCH="rm" /bin/bash "$ROOT/dev-shell.sh" < /dev/null > /dev/null 2>&1; then
    fail "the machine wrapper launched an arbitrary AIBOX_DEV_LAUNCH command"
fi

# The user env file is imported by the unprivileged command wrapper, not by root startup.
ENTRYPOINT_HOME="$TMP_ROOT/entrypoint-home"
ENTRYPOINT_RESULT="$TMP_ROOT/entrypoint-user-env.result"
BASH_ENV_MARKER="$TMP_ROOT/bash-env.marker"
BASH_ENV_HOOK="$TMP_ROOT/bash-env-hook"
DELAYED_ENV_FILE="$TMP_ROOT/delayed-user-env"
mkdir -p "$ENTRYPOINT_HOME"
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

cat > "$TEST_HOME/.aibox/aibox.conf" <<'CONF'
AIBOX_PROXY=""
AIBOX_TZ="UTC"
AIBOX_LANG="C.UTF-8"
AIBOX_ENV_VARS=()
CONF

# ---- v0.2.0: user data lives in ~/.aibox; the program directory stays read-only ----
STATE="$TEST_HOME/.aibox"

# aibox refuses to run outside macOS or as root: there $HOME is not the Mac user's home and
# the state directory would land on a container disk or in root's home.
reset_stub_files
if PATH="$STUB_BIN:$ORIGINAL_PATH" STUB_UNAME=Linux HOME="$TEST_HOME" "$FIXTURE/ai-box" tmp list \
    > "$TMP_ROOT/linux-guard.output" 2>&1; then
    fail "aibox ran on a non-macOS system"
fi
assert_file_contains "$TMP_ROOT/linux-guard.output" 'macOS' "the non-macOS refusal did not explain itself"
[ ! -e "$STUB_CALLED" ] || fail "the non-macOS refusal still reached the container CLI"
PATH="$STUB_BIN:$ORIGINAL_PATH" STUB_UNAME=Linux "$FIXTURE/ai-box" --version > /dev/null \
    || fail "aibox --version must work everywhere"

# The old layout (config and gost in the program directory) moves into ~/.aibox once. The config
# leaves a link behind so habits keep working. The Gradle cache is no longer used and stays put;
# aibox setup offers to delete it.
mv "$STATE/aibox.conf" "$TMP_ROOT/state-conf.saved"
printf 'AIBOX_TZ="UTC"\n' > "$FIXTURE/aibox.conf"
mkdir -p "$FIXTURE/third_party" "$FIXTURE/cache/gradle/caches"
printf 'fake-gost\n' > "$FIXTURE/third_party/gost"
printf 'cached\n' > "$FIXTURE/cache/gradle/caches/entry"
reset_stub_files
run_fixture_command status > "$TMP_ROOT/relocate.output" 2>&1 || fail "relocating the old layout failed"
assert_file_contains "$TMP_ROOT/relocate.output" '已把' "relocation did not report what it moved"
assert_file_has_line "$STATE/aibox.conf" 'AIBOX_TZ="UTC"' "aibox.conf was not moved into ~/.aibox"
[ -L "$FIXTURE/aibox.conf" ] && [ "$(readlink "$FIXTURE/aibox.conf")" = "$STATE/aibox.conf" ] \
    || fail "the old aibox.conf location does not link to the new one"
[ "$(file_mode_of "$STATE/aibox.conf")" = "600" ] || fail "the moved aibox.conf is not mode 600"
assert_file_has_line "$STATE/third_party/gost" 'fake-gost' "third_party/gost was not moved"
[ ! -e "$FIXTURE/third_party/gost" ] || fail "third_party/gost was left in the program directory"
[ ! -e "$STATE/cache" ] || fail "the unused Gradle cache was moved into ~/.aibox"
assert_file_has_line "$FIXTURE/cache/gradle/caches/entry" 'cached' "the old Gradle cache was touched"
rm -rf "$FIXTURE/cache"
run_fixture_command status > "$TMP_ROOT/relocate-again.output" 2>&1 || fail "a second run failed"
assert_file_omits "$TMP_ROOT/relocate-again.output" '已把' "relocation ran twice"
# A stale copy left in the old place is pointed out instead of silently ignored.
printf 'stale-gost\n' > "$FIXTURE/third_party/gost"
run_fixture_command status > "$TMP_ROOT/relocate-stale.output" 2>&1 || fail "status with a stale asset failed"
assert_file_contains "$TMP_ROOT/relocate-stale.output" 'third_party/gost 已不再使用' \
    "a stale third_party file in the program directory was ignored silently"
assert_file_has_line "$STATE/third_party/gost" 'fake-gost' "a stale asset overwrote the active one"
rm -f "$FIXTURE/third_party/gost"
rm -f "$FIXTURE/aibox.conf"
mv "$TMP_ROOT/state-conf.saved" "$STATE/aibox.conf"

# Builds use a staged context: program files from the .dockerignore allowlist plus gost
# from ~/.aibox; nothing else from either directory (the old JDK / Maven archives included).
printf 'local-secret\n' > "$FIXTURE/not-in-allowlist.txt"
printf 'old-jdk\n' > "$STATE/third_party/jdk8.tar.gz"
reset_stub_files
run_fixture_command tmp build > "$TMP_ROOT/stage-build.output" 2>&1 || fail "staged build failed"
for staged in ./Dockerfile ./entrypoint.sh ./.dockerignore ./third_party/gost ./clipboard-bridge/xclip-shim.sh; do
    assert_file_has_line "$STUB_BUILD_CONTEXT" "$staged" "the build context is missing $staged"
done
assert_file_omits "$STUB_BUILD_CONTEXT" 'not-in-allowlist.txt' "the build context leaked a non-allowlisted file"
assert_file_omits "$STUB_BUILD_CONTEXT" 'aibox.conf' "the build context leaked aibox.conf"
assert_file_omits "$STUB_BUILD_CONTEXT" 'jdk8.tar.gz' "the build context still picks up the old JDK archive"
rm -f "$STATE/third_party/jdk8.tar.gz"
if find "$RUN_TMP" -maxdepth 1 -name 'aibox-build.*' | grep -q .; then
    fail "the staged build context was not cleaned up"
fi
rm -f "$FIXTURE/not-in-allowlist.txt"

# aibox tmp update records upgrades in ~/.aibox/versions.env instead of editing the Dockerfile;
# builds pass the newer version, and the Dockerfile default wins once it is newer.
cp "$FIXTURE/Dockerfile" "$TMP_ROOT/Dockerfile.before"
reset_stub_files
printf 'y\n' | run_fixture_command tmp update cc > "$TMP_ROOT/tmp-update.output" 2>&1 \
    || fail "aibox tmp update failed"
cmp -s "$TMP_ROOT/Dockerfile.before" "$FIXTURE/Dockerfile" || fail "aibox tmp update edited the Dockerfile"
assert_file_has_line "$STATE/versions.env" 'CLAUDE_CODE_VERSION=9.9.9' "the upgraded version was not recorded"
assert_file_contains "$STUB_CALLS" 'NPM_SPECS=@anthropic-ai/claude-code@9.9.9' \
    "the incremental update did not install the recorded version"
run_fixture_command tmp version > "$TMP_ROOT/tmp-version.output" 2>&1 || fail "aibox tmp version failed"
assert_file_contains "$TMP_ROOT/tmp-version.output" 'claude-code: 9.9.9' "tmp version ignored versions.env"
reset_stub_files
run_fixture_command tmp build > "$TMP_ROOT/pinned-build.output" 2>&1 || fail "pinned build failed"
assert_file_contains "$STUB_CALLS" '--build-arg CLAUDE_CODE_VERSION=9.9.9' "the build ignored versions.env"
printf 'CLAUDE_CODE_VERSION=0.0.1\n' > "$STATE/versions.env"
reset_stub_files
run_fixture_command tmp build > "$TMP_ROOT/older-pin-build.output" 2>&1 || fail "build with an older pin failed"
default_claude="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$FIXTURE/Dockerfile")"
assert_file_contains "$STUB_CALLS" "--build-arg CLAUDE_CODE_VERSION=$default_claude" \
    "an older local version overrode a newer Dockerfile default"
rm -f "$STATE/versions.env"
# The user's own --build-arg comes after the recorded versions, so it wins.
reset_stub_files
run_fixture_command tmp build --build-arg CLAUDE_CODE_VERSION=1.2.3 > "$TMP_ROOT/user-arg-build.output" 2>&1 \
    || fail "build with a user --build-arg failed"
assert_file_contains "$STUB_CALLS" '--build-arg CLAUDE_CODE_VERSION=1.2.3 -t ai-sandbox:latest .' \
    "a user --build-arg was not passed last"

# A git checkout whose only local Dockerfile change is the CLI version lines (left by the old
# aibox tmp update) gets them moved into versions.env and the Dockerfile restored.
if command -v git >/dev/null 2>&1; then
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" -c user.email=t@example.invalid -c user.name=t add Dockerfile
    git -C "$FIXTURE" -c user.email=t@example.invalid -c user.name=t commit -q -m base
    sed 's/^ARG CODEX_VERSION=.*/ARG CODEX_VERSION=8.8.8/' "$FIXTURE/Dockerfile" > "$TMP_ROOT/Dockerfile.pinned"
    cp "$TMP_ROOT/Dockerfile.pinned" "$FIXTURE/Dockerfile"
    run_fixture_command status > "$TMP_ROOT/pin-relocate.output" 2>&1 || fail "relocating Dockerfile pins failed"
    assert_file_has_line "$STATE/versions.env" 'CODEX_VERSION=8.8.8' "the old Dockerfile pin was not kept"
    git -C "$FIXTURE" diff --quiet -- Dockerfile || fail "the Dockerfile was not restored"
    # Other local Dockerfile edits belong to the user and stay untouched.
    rm -f "$STATE/versions.env"
    printf '# my change\n' >> "$FIXTURE/Dockerfile"
    run_fixture_command status > "$TMP_ROOT/pin-keep.output" 2>&1 || fail "status with a custom Dockerfile failed"
    [ ! -f "$STATE/versions.env" ] || fail "a user's own Dockerfile edits were treated as version pins"
    grep -qxF '# my change' "$FIXTURE/Dockerfile" || fail "a user's own Dockerfile edits were reverted"
    git -C "$FIXTURE" checkout -q -- Dockerfile
    rm -rf "$FIXTURE/.git"
fi

# The persistent container syncs helpers from ~/.aibox/machine, so the program directory may
# live anywhere (outside the home in a Homebrew install).
reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
run_fixture_command start > "$TMP_ROOT/stage-machine.output" 2>&1 || fail "start with staged helpers failed"
for helper in dev-profile.sh dev-shell.sh dev-configure.sh dev-proxy-run.sh dev-tools.sh aibox-dev-proxy.service; do
    cmp -s "$FIXTURE/$helper" "$STATE/machine/$helper" || fail "$helper was not staged for the machine"
done
assert_file_contains "$STUB_ENV_LOG" "AIBOX_STAGE=$STATE/machine" "the root step did not get the staging directory"
assert_file_contains "$STUB_CALLS" '$stage/dev-shell.sh' "the root step does not sync from the staging directory"
assert_file_contains "$STUB_CALLS" '/third_party/gost' "the root step does not sync gost from ~/.aibox"
STUB_MACHINE_LIST=""

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
run_fixture_command tmp "$TEST_HOME" > "$TMP_ROOT/clip-nested.output" 2>&1 \
    || fail "launch with the home directory as the project failed"
assert_file_omits "$STUB_ARGS" '/run/aibox/clipboard-bridge' \
    "the bridge was mounted twice when the project directory already contained it"
clip_nested_project="$(basename "$TEST_HOME")"
assert_arg_pair -e "CLIP_BRIDGE_DIR=/workspace/$clip_nested_project/.clipboard-bridge"

# The persistent development machine mounts the host home at a matching path, so
# the value travels through its env-file unchanged.
reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
run_fixture_command > "$TMP_ROOT/clip-dev.output" 2>&1 \
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
run_fixture_command status > "$TMP_ROOT/clip-dev-status.output" 2>&1 \
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

# ---- Setup wizard ----
# The wizard runs against its own clean checkout and HOME. uname/sw_vers/id/launchctl are
# stubbed so the macOS-only flow also runs on Linux CI; curl fails so nothing touches the network.
SETUP_FIXTURE="$TMP_ROOT/setup-repo"
SETUP_HOME="$TMP_ROOT/setup-home"
SETUP_BIN="$TMP_ROOT/setup-bin"
mkdir -p "$SETUP_FIXTURE" "$SETUP_HOME" "$SETUP_BIN"
cp "$ROOT/ai-box" "$ROOT/aibox-ui.sh" "$ROOT/setup.sh" "$ROOT/aibox.conf.example" "$ROOT/ai-box-completion.sh" \
    "$ROOT/Dockerfile" "$ROOT/entrypoint.sh" "$SETUP_FIXTURE/"
chmod +x "$SETUP_FIXTURE/ai-box" "$SETUP_FIXTURE/setup.sh"
# The wizard records physical paths; on macOS the temp directory sits behind the /var symlink.
SETUP_FIXTURE_REAL="$(cd -P "$SETUP_FIXTURE" && pwd)"

cat > "$SETUP_BIN/uname" <<'STUB'
#!/bin/sh
case "${1:-}" in
    -m) echo arm64 ;;
    *)  echo Darwin ;;
esac
STUB
cat > "$SETUP_BIN/sw_vers" <<'STUB'
#!/bin/sh
echo 26.0
STUB
cat > "$SETUP_BIN/id" <<'STUB'
#!/bin/sh
echo 501
STUB
cat > "$SETUP_BIN/launchctl" <<'STUB'
#!/bin/sh
exit 1
STUB
# A 16G / 8-core Mac, so the resource limits in the wizard are deterministic.
cat > "$SETUP_BIN/sysctl" <<'STUB'
#!/bin/sh
case "${2:-}" in
    hw.memsize) echo 17179869184 ;;
    hw.ncpu) echo 8 ;;
    hw.optional.arm64) echo 1 ;;
    *) exit 1 ;;
esac
STUB
# The proxy probe gets a canned API response when SETUP_CURL_CODE is set; the proxy config
# curl reads from stdin is saved so the test can check which URL scheme was used.
cat > "$SETUP_BIN/curl" <<'STUB'
#!/bin/sh
out=""
probe=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        https://api.anthropic.com/*) probe=1 ;;
    esac
    shift
done
if [ "$probe" -eq 1 ] && [ -n "${SETUP_CURL_CODE:-}" ]; then
    cat > "$SETUP_CURL_STDIN"
    printf '%s' "${SETUP_CURL_BODY:-}" > "$out"
    printf '\n%s' "$SETUP_CURL_CODE"
    exit 0
fi
echo "curl: network is disabled in smoke tests" >&2
exit 7
STUB
chmod +x "$SETUP_BIN"/*

run_setup() (
    export HOME="$SETUP_HOME"
    export SHELL=/bin/zsh
    export LANG=en_US.UTF-8
    export NO_COLOR=1
    export TMPDIR="$RUN_TMP"
    export PATH="$SETUP_BIN:$HOST_STUB_PATH"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export STUB_CALLS STUB_ENV_LOG STUB_LS_RUNNING STUB_LS_ALL STUB_MACHINE_LIST STUB_MACHINE_LIST_FAIL STUB_IMAGE_PRESENT
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL STUB_MACHINE_HOME STUB_MACHINE_BUSY STUB_CONTAINER_VERSION STUB_BUILD_CONTEXT
    export SETUP_CURL_CODE SETUP_CURL_BODY SETUP_CURL_STDIN
    unset AIBOX_PROXY AIBOX_TZ AIBOX_LANG AIBOX_MEMORY AIBOX_CPUS
    unset FIXED_SOCKS_HOST FIXED_SOCKS_PORT FIXED_SOCKS_USER FIXED_SOCKS_PASS
    "$SETUP_FIXTURE/setup.sh" "$@"
)

# Prints the sourced config values one per line, exactly as ai-box would read them.
setup_conf_values() (
    set +u
    AIBOX_ENV_VARS=()
    . "$SETUP_HOME/.aibox/aibox.conf"
    printf 'PROXY=%s\n' "$AIBOX_PROXY"
    printf 'TZ=%s\n' "$AIBOX_TZ"
    printf 'LANG=%s\n' "$AIBOX_LANG"
    printf 'MEMORY=%s\n' "$AIBOX_MEMORY"
    printf 'CPUS=%s\n' "$AIBOX_CPUS"
    for setup_entry in "${AIBOX_ENV_VARS[@]}"; do
        printf 'ENV=%s\n' "$setup_entry"
    done
)

STUB_LS_RUNNING=""
STUB_IMAGE_PRESENT=1
STUB_MACHINE_LIST=""
STUB_MACHINE_HOME=""
SETUP_CURL_CODE=""
SETUP_CURL_BODY=""
SETUP_CURL_STDIN="$TMP_ROOT/setup-curl.stdin"
reset_stub_files

# --check reports what is missing and changes nothing.
if run_setup --check < /dev/null > "$TMP_ROOT/setup-check.output" 2>&1; then
    fail "setup --check passed before the aibox command was installed"
fi
assert_file_contains "$TMP_ROOT/setup-check.output" '还没有安装 aibox 命令' \
    "setup --check did not report the missing aibox command"
[ ! -e "$SETUP_HOME/.local/bin/aibox" ] || fail "setup --check created the aibox link"
[ ! -e "$SETUP_HOME/.zshrc" ] || fail "setup --check modified the shell profile"
[ ! -e "$SETUP_HOME/.aibox/aibox.conf" ] || fail "setup --check created aibox.conf"

# A full first run. Answers follow the prompt order; outside a terminal the menus take their
# item numbers. Time zone, language, memory and CPU go through the manual-entry item, where
# invalid entries prove re-prompting (including memory / CPU above what the Mac has),
# the localhost proxy is rewritten to the container gateway, and the secret keeps quotes,
# a dollar sign and a backslash verbatim.
SETUP_PROXY_INPUT='socks5h://us%40er:pa'"'"'ss$word"x@127.0.0.1:1080/'
SETUP_PROXY_EXPECTED='socks5h://us%40er:pa'"'"'ss$word"x@192.168.64.1:1080'
SETUP_KEY_INPUT='  sk-ant-'"'"'quote$HOME"x \back  '
SETUP_KEY_EXPECTED='sk-ant-'"'"'quote$HOME"x \back'
printf '%s\n' \
    '' 'y' 'y' \
    'y' \
    '2' "$SETUP_PROXY_INPUT" 'y' 'n' 'y' \
    '11' 'bad zone' 'UTC' \
    '7' 'xx_XX.UTF-8' 'zh_CN.UTF-8' \
    '5' '8GB' '32G' '12g' \
    '6' 'x' '16' '4' \
    '2' "$SETUP_KEY_INPUT" 'ftp://nope' '' '' \
    'y' \
    'n' \
    | SETUP_CURL_CODE=401 \
      SETUP_CURL_BODY='{"type":"error","error":{"type":"authentication_error","message":"x-api-key header is required"}}' \
      run_setup > "$TMP_ROOT/setup-first.output" 2>&1 && setup_status=0 || setup_status=$?
[ "$setup_status" -eq 1 ] \
    || fail "first setup run should end with gost pending (status $setup_status)"
assert_file_contains "$TMP_ROOT/setup-first.output" 'third_party/gost' \
    "setup did not list the missing gost as pending"
[ -L "$SETUP_HOME/.local/bin/aibox" ] || fail "setup did not create the aibox link"
[ "$(readlink "$SETUP_HOME/.local/bin/aibox")" = "$SETUP_FIXTURE_REAL/ai-box" ] \
    || fail "aibox link does not point at the checkout"
assert_file_has_line "$SETUP_HOME/.zshrc" 'export PATH="$HOME/.local/bin:$PATH"' \
    "setup did not add ~/.local/bin to PATH"
assert_file_has_line "$SETUP_HOME/.zshrc" "source '$SETUP_FIXTURE_REAL/ai-box-completion.sh'" \
    "setup did not enable completion"
[ "$(file_mode_of "$SETUP_HOME/.aibox/aibox.conf")" = "600" ] || fail "aibox.conf is not mode 600"
bash -n "$SETUP_HOME/.aibox/aibox.conf" || fail "generated aibox.conf has a syntax error"
printf '%s\n' \
    "PROXY=$SETUP_PROXY_EXPECTED" 'TZ=UTC' 'LANG=zh_CN.UTF-8' 'MEMORY=12G' 'CPUS=4' \
    "ENV=ANTHROPIC_API_KEY=$SETUP_KEY_EXPECTED" > "$TMP_ROOT/setup-first.expected"
setup_conf_values > "$TMP_ROOT/setup-first.actual" || fail "generated aibox.conf cannot be sourced"
cmp -s "$TMP_ROOT/setup-first.expected" "$TMP_ROOT/setup-first.actual" \
    || fail "generated aibox.conf does not round-trip the answers"
if grep -rq 'sk-ant-' "$TMP_ROOT/setup-first.output"; then
    fail "setup echoed the API key"
fi
assert_file_contains "$TMP_ROOT/setup-first.output" '已接通 Claude API' \
    "the proxy probe did not accept the Claude API's own 401"
assert_file_contains "$SETUP_CURL_STDIN" 'proxy = "socks5h://us%40er:' \
    "the proxy probe did not pass the proxy to curl through stdin"
assert_file_contains "$TMP_ROOT/setup-first.output" '超过了本机内存' \
    "setup accepted more memory than the Mac has"
assert_file_contains "$TMP_ROOT/setup-first.output" '超过了本机的 8 核' \
    "setup accepted more CPUs than the Mac has"

# ai-box itself must accept the generated file and forward the key through the env-file.
reset_stub_files
(
    export HOME="$SETUP_HOME" PATH="$HOST_STUB_PATH" TMPDIR="$RUN_TMP"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export STUB_CALLS STUB_ENV_LOG STUB_LS_RUNNING STUB_LS_ALL STUB_MACHINE_LIST STUB_MACHINE_LIST_FAIL STUB_IMAGE_PRESENT
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL STUB_MACHINE_HOME STUB_MACHINE_BUSY STUB_CONTAINER_VERSION STUB_BUILD_CONTEXT
    unset AIBOX_PROXY AIBOX_TZ AIBOX_LANG AIBOX_MEMORY AIBOX_CPUS
    "$SETUP_FIXTURE/ai-box" tmp "$PROJECT"
) > "$TMP_ROOT/setup-launch.output" 2>&1 || fail "ai-box rejected the generated aibox.conf"
assert_file_has_line "$STUB_ENV_COPY" "ANTHROPIC_API_KEY=$SETUP_KEY_EXPECTED" \
    "generated API key did not reach the env-file verbatim"
assert_arg_pair --cap-add CAP_NET_ADMIN
assert_arg_pair --memory 12G
assert_arg_pair --cpus 4

# A second run skips finished steps and must not duplicate profile lines or touch the config.
cp -p "$SETUP_HOME/.aibox/aibox.conf" "$TMP_ROOT/setup-conf.before"
printf '%s\n' '' 'n' 'n' \
    | run_setup > "$TMP_ROOT/setup-second.output" 2>&1 && setup_status=0 || setup_status=$?
[ "$setup_status" -eq 1 ] || fail "second setup run should still report gost (status $setup_status)"
[ "$(grep -cxF 'export PATH="$HOME/.local/bin:$PATH"' "$SETUP_HOME/.zshrc")" -eq 1 ] \
    || fail "setup duplicated the PATH line"
[ "$(grep -cxF "source '$SETUP_FIXTURE_REAL/ai-box-completion.sh'" "$SETUP_HOME/.zshrc")" -eq 1 ] \
    || fail "setup duplicated the completion line"
cmp -s "$TMP_ROOT/setup-conf.before" "$SETUP_HOME/.aibox/aibox.conf" \
    || fail "declining to modify the config still changed it"
if ls "$SETUP_HOME/.aibox"/aibox.conf.bak.* >/dev/null 2>&1; then
    fail "declining to modify the config created a backup"
fi

# Reconfiguring keeps current values by default, preserves unrelated AIBOX_ENV_VARS
# entries, tightens loose permissions and backs up the previous file.
# The persistent machine already exists, so the changed memory is offered to it via aibox set.
reset_stub_files
STUB_MACHINE_LIST="aibox-dev"
printf '%s\n' "AIBOX_ENV_VARS+=('CUSTOM_KEEP=kept value')" >> "$SETUP_HOME/.aibox/aibox.conf"
chmod 644 "$SETUP_HOME/.aibox/aibox.conf"
# The proxy changes to plain socks5://; the probe must still let the proxy resolve names
# (as gost does in the container) and must not count a 404 from elsewhere as connected.
SETUP_PROXY_SOCKS5='socks5://user2:pw2@proxy.example.invalid:443'
printf '%s\n' \
    'y' 'y' \
    '' '2' "$SETUP_PROXY_SOCKS5" 'n' 'y' \
    '' \
    '' \
    '4' '' \
    '' '' 'https://relay.example.invalid/api' '' \
    '' \
    'y' \
    'n' \
    | SETUP_CURL_CODE=404 SETUP_CURL_BODY='Not Found' \
      run_setup > "$TMP_ROOT/setup-third.output" 2>&1 && setup_status=0 || setup_status=$?
[ "$setup_status" -eq 1 ] || fail "third setup run should still report gost (status $setup_status)"
printf '%s\n' \
    "PROXY=$SETUP_PROXY_SOCKS5" 'TZ=UTC' 'LANG=zh_CN.UTF-8' 'MEMORY=16G' 'CPUS=4' \
    'ENV=CUSTOM_KEEP=kept value' \
    "ENV=ANTHROPIC_API_KEY=$SETUP_KEY_EXPECTED" \
    'ENV=ANTHROPIC_BASE_URL=https://relay.example.invalid/api' > "$TMP_ROOT/setup-third.expected"
setup_conf_values > "$TMP_ROOT/setup-third.actual" || fail "reconfigured aibox.conf cannot be sourced"
cmp -s "$TMP_ROOT/setup-third.expected" "$TMP_ROOT/setup-third.actual" \
    || fail "reconfiguring did not keep existing values and unrelated entries"
[ "$(file_mode_of "$SETUP_HOME/.aibox/aibox.conf")" = "600" ] || fail "reconfigured aibox.conf is not mode 600"
setup_backup="$(ls "$SETUP_HOME/.aibox"/aibox.conf.bak.* 2>/dev/null | head -n 1)"
[ -n "$setup_backup" ] || fail "reconfiguring did not back up the previous config"
[ "$(file_mode_of "$setup_backup")" = "600" ] || fail "config backup is not mode 600"
grep -qF 'CUSTOM_KEEP' "$setup_backup" || fail "config backup does not hold the previous content"
assert_file_contains "$SETUP_CURL_STDIN" 'proxy = "socks5h://user2:pw2@proxy.example.invalid:443"' \
    "the proxy probe resolved names locally for a socks5:// proxy"
assert_file_contains "$TMP_ROOT/setup-third.output" '不是 Claude API 的预期结果(HTTP 404)' \
    "the proxy probe counted a non-Claude 404 as connected"
if grep -q '已接通 Claude API' "$TMP_ROOT/setup-third.output"; then
    fail "the proxy probe reported a 404 as connected"
fi
assert_file_contains "$STUB_CALLS" 'CALL machine set --name aibox-dev memory=16G cpus=4' \
    "changed resources were not synced to the existing persistent machine"
STUB_MACHINE_LIST=""

# Switching to direct mode and account login drops the proxy and the managed keys,
# keeps unrelated entries, and leaves nothing pending.
printf '%s\n' \
    'y' \
    '1' \
    '1' \
    '1' \
    '1' '1' \
    '1' '' \
    'y' \
    'n' \
    | run_setup > "$TMP_ROOT/setup-fourth.output" 2>&1 \
    || fail "setup should be complete after switching to direct mode"
printf '%s\n' 'PROXY=' 'TZ=' 'LANG=' 'MEMORY=' 'CPUS=' 'ENV=CUSTOM_KEEP=kept value' \
    > "$TMP_ROOT/setup-fourth.expected"
setup_conf_values > "$TMP_ROOT/setup-fourth.actual" || fail "direct-mode aibox.conf cannot be sourced"
cmp -s "$TMP_ROOT/setup-fourth.expected" "$TMP_ROOT/setup-fourth.actual" \
    || fail "switching to account login did not drop only the managed keys"

run_setup --check < /dev/null > "$TMP_ROOT/setup-final-check.output" 2>&1 \
    || fail "setup --check still reports pending items after a complete setup"

# The wizard compares Apple container with the minimum and the verified versions.
STUB_CONTAINER_VERSION="0.9.0"
if run_setup --check < /dev/null > "$TMP_ROOT/setup-old-container.output" 2>&1; then
    fail "setup --check accepted an Apple container below the minimum version"
fi
assert_file_contains "$TMP_ROOT/setup-old-container.output" 'update-container.sh -v 1.6.0' \
    "setup did not explain how to upgrade an old Apple container"
STUB_CONTAINER_VERSION="9.9.9"
run_setup --check < /dev/null > "$TMP_ROOT/setup-new-container.output" 2>&1 \
    || fail "a newer, unverified Apple container must only warn"
assert_file_contains "$TMP_ROOT/setup-new-container.output" '尚未经过验证' \
    "setup did not flag an unverified newer Apple container"
STUB_CONTAINER_VERSION="1.6.0"

# ---- Homebrew layout: <prefix>/Cellar/aibox/<version>/libexec, linked via opt/ and bin/ ----
BREW="$TMP_ROOT/brew"
BREW_LIBEXEC="$BREW/Cellar/aibox/9.9.9/libexec"
mkdir -p "$BREW_LIBEXEC" "$BREW/bin" "$BREW/Cellar/aibox/9.9.9/bin"
cp -R "$SETUP_FIXTURE/." "$BREW_LIBEXEC/"
cp "$ROOT/.dockerignore" "$ROOT/Dockerfile.update" "$ROOT/network-lockdown.sh" "$ROOT/user-exec.sh" \
    "$ROOT/enter-shell.sh" "$ROOT/dev-profile.sh" "$ROOT/dev-shell.sh" "$ROOT/dev-configure.sh" \
    "$ROOT/dev-proxy-run.sh" "$ROOT/dev-tools.sh" "$ROOT/aibox-dev-proxy.service" "$BREW_LIBEXEC/"
cp -R "$ROOT/clipboard-bridge" "$BREW_LIBEXEC/clipboard-bridge"
rm -rf "$BREW_LIBEXEC/creds" "$BREW_LIBEXEC/cache"
ln -s ../libexec/ai-box "$BREW/Cellar/aibox/9.9.9/bin/aibox"
ln -s ../Cellar/aibox/9.9.9/bin/aibox "$BREW/bin/aibox"
ln -s ../Cellar/aibox/9.9.9 "$BREW/opt/aibox" 2>/dev/null || { mkdir -p "$BREW/opt"; ln -s ../Cellar/aibox/9.9.9 "$BREW/opt/aibox"; }

PATH="$STUB_BIN:$ORIGINAL_PATH" "$BREW/bin/aibox" --version | grep -q '(Homebrew)' \
    || fail "aibox --version did not recognize a Homebrew install"

# The wizard on a Homebrew install: the old ~/.local/bin/aibox link from the git clone shadows
# the brew one, and the completion line still points at the clone. Both get fixed; the old
# completion line is commented out, not deleted.
[ -L "$SETUP_HOME/.local/bin/aibox" ] || fail "test setup: the clone link from earlier cases is missing"
printf '%s\n' 'y' 'y' 'n' 'n' | (
    export HOME="$SETUP_HOME" SHELL=/bin/zsh LANG=en_US.UTF-8 NO_COLOR=1 TMPDIR="$RUN_TMP"
    export PATH="$SETUP_HOME/.local/bin:$BREW/bin:$SETUP_BIN:$HOST_STUB_PATH"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export STUB_CALLS STUB_ENV_LOG STUB_LS_RUNNING STUB_LS_ALL STUB_MACHINE_LIST STUB_MACHINE_LIST_FAIL STUB_IMAGE_PRESENT
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL STUB_MACHINE_HOME STUB_MACHINE_BUSY STUB_CONTAINER_VERSION STUB_BUILD_CONTEXT
    unset AIBOX_PROXY AIBOX_TZ AIBOX_LANG AIBOX_MEMORY AIBOX_CPUS
    "$BREW_LIBEXEC/setup.sh"
) > "$TMP_ROOT/setup-brew.output" 2>&1 || { cat "$TMP_ROOT/setup-brew.output" >&2; fail "the wizard on a Homebrew install reported pending steps"; }
assert_file_contains "$TMP_ROOT/setup-brew.output" '通过 Homebrew 安装' "the wizard did not detect Homebrew"
[ ! -e "$SETUP_HOME/.local/bin/aibox" ] || fail "the shadowing clone link was not removed"
BREW_REAL="$(cd -P "$BREW" && pwd)"
assert_file_has_line "$SETUP_HOME/.zshrc" "source '$BREW_REAL/opt/aibox/libexec/ai-box-completion.sh'" \
    "completion was not switched to the stable opt path"
grep -qF "# (aibox setup 已停用) source '$SETUP_FIXTURE_REAL/ai-box-completion.sh'" "$SETUP_HOME/.zshrc" \
    || fail "the old completion line was not kept as a comment"
[ "$(grep -c '^[^#]*ai-box-completion.sh' "$SETUP_HOME/.zshrc")" -eq 1 ] \
    || fail "more than one active completion line remains"

# A read-only program directory still works: config, builds and launches only write to ~/.aibox.
chmod -R a-w "$BREW_LIBEXEC"
reset_stub_files
(
    export HOME="$TEST_HOME" PATH="$HOST_STUB_PATH" TMPDIR="$RUN_TMP"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export STUB_CALLS STUB_ENV_LOG STUB_LS_RUNNING STUB_LS_ALL STUB_MACHINE_LIST STUB_MACHINE_LIST_FAIL STUB_IMAGE_PRESENT
    export STUB_MACHINE_INSPECT_JSON STUB_MACHINE_INSPECT_FAIL STUB_DEV_SYSTEMD_FAIL STUB_MACHINE_HOME STUB_MACHINE_BUSY STUB_CONTAINER_VERSION STUB_BUILD_CONTEXT
    unset AIBOX_PROXY AIBOX_TZ AIBOX_LANG AIBOX_MEMORY AIBOX_CPUS
    "$BREW/bin/aibox" tmp build && "$BREW/bin/aibox" tmp version && "$BREW/bin/aibox" tmp "$PROJECT"
) > "$TMP_ROOT/brew-readonly.output" 2>&1 || { chmod -R u+w "$BREW_LIBEXEC"; fail "a read-only Homebrew install failed to build or launch"; }
chmod -R u+w "$BREW_LIBEXEC"
assert_file_contains "$STUB_CALLS" 'CALL run --rm -it' "the read-only install did not launch a temporary container"

# Legacy login state that has not been migrated yet shows up as a pending step.
mv "$SETUP_HOME/.aibox/.migrated" "$TMP_ROOT/setup-migrated.saved"
mkdir -p "$SETUP_FIXTURE/creds/claude"
printf 'legacy\n' > "$SETUP_FIXTURE/creds/claude/CLAUDE.md"
if run_setup --check < /dev/null > "$TMP_ROOT/setup-legacy-check.output" 2>&1; then
    fail "setup --check ignored unmigrated legacy state"
fi
assert_file_contains "$TMP_ROOT/setup-legacy-check.output" 'aibox migrate' \
    "setup --check did not point at aibox migrate"
rm -rf "$SETUP_FIXTURE/creds"
mv "$TMP_ROOT/setup-migrated.saved" "$SETUP_HOME/.aibox/.migrated"

echo "smoke tests passed"
