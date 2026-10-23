# Claude and Codex state lives in the host's ~/.aibox, shared with the ephemeral
# `aibox tmp` containers and kept apart from the Mac's own ~/.claude and ~/.codex.
# The machine user's $HOME is /home/<user> on the system disk; the host home is
# mounted at its original path, which the launcher records in /etc/aibox/state-dir.
aibox_state_dir="$HOME/.aibox"
# Use the shell builtin: a custom PATH from AIBOX_ENV_VARS may not contain /bin.
if [ -r /etc/aibox/state-dir ]; then
    aibox_state_line=""
    IFS= read -r aibox_state_line < /etc/aibox/state-dir || true
    [ -z "$aibox_state_line" ] || aibox_state_dir="$aibox_state_line"
    unset aibox_state_line
fi
export CLAUDE_CONFIG_DIR="$aibox_state_dir/claude"
export CODEX_HOME="$aibox_state_dir/codex"
unset aibox_state_dir
# The CLIs are installed system-wide by root (npm -g into /usr/local), so Claude
# Code's own auto-updater cannot write there and only prints "Auto-update failed:
# no write permission to npm prefix". Upgrades go through `aibox update`.
export DISABLE_AUTOUPDATER=1
