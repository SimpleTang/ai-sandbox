#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n \
    "$ROOT/ai-box" \
    "$ROOT/entrypoint.sh" \
    "$ROOT/ai-box-completion.sh"

help_output="$($ROOT/ai-box --help)"
case "$help_output" in
    *"aibox"*"build"*"status"*) ;;
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
ORIGINAL_PATH="$PATH"
HOST_STUB_PATH="$STUB_BIN:$ORIGINAL_PATH"

mkdir -p "$FIXTURE" "$STUB_BIN" "$TEST_HOME" "$RUN_TMP" "$PROJECT"
cp "$ROOT/ai-box" "$ROOT/Dockerfile" "$ROOT/entrypoint.sh" "$FIXTURE/"

cat > "$STUB_BIN/container" <<'STUB'
#!/usr/bin/env bash
set -eu

: > "$STUB_CALLED"
: > "$STUB_ARGS"
: > "$STUB_ENV_PATH"
env_file=""
expect_env_file=0
for arg in "$@"; do
    printf '%s\n' "$arg" >> "$STUB_ARGS"
    if [ "$expect_env_file" -eq 1 ]; then
        env_file="$arg"
        expect_env_file=0
    elif [ "$arg" = "--env-file" ]; then
        expect_env_file=1
    fi
done
[ "$expect_env_file" -eq 0 ] || exit 64

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

reset_stub_files() {
    rm -f "$STUB_ARGS" "$STUB_CALLED" "$STUB_ENV_COPY" "$STUB_ENV_PATH" \
        "$STUB_ENV_MODE" "$STUB_HOST_ENV"
}

run_fixture() (
    export HOME="$TEST_HOME"
    export PATH="$HOST_STUB_PATH"
    export TMPDIR="$RUN_TMP"
    export STUB_ARGS STUB_CALLED STUB_ENV_COPY STUB_ENV_PATH STUB_ENV_MODE STUB_HOST_ENV
    export ANTHROPIC_API_KEY="host-anthropic-key-must-not-be-forwarded"
    unset OPENAI_API_KEY AIBOX_PROXY AIBOX_TZ AIBOX_LANG
    unset FIXED_SOCKS_HOST FIXED_SOCKS_PORT FIXED_SOCKS_USER FIXED_SOCKS_PASS
    "$FIXTURE/ai-box" "$PROJECT"
)

# An explicitly empty indexed array must work under macOS Bash 3.2 + set -u and must
# not create or pass an env-file.
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
assert_file_omits "$STUB_ARGS" 'ANTHROPIC_API_KEY' \
    "unlisted host ANTHROPIC_API_KEY was forwarded"
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
assert_arg_pair --env-file "$env_file_path"
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

echo "smoke tests passed"
