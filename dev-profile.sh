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

if [ -x /opt/java/jdk8/bin/java ]; then
    export JAVA_HOME=/opt/java/jdk8
    export PATH="$JAVA_HOME/bin:$PATH"
fi
if [ -x /opt/maven/bin/mvn ]; then
    export MAVEN_HOME=/opt/maven
    export PATH="$MAVEN_HOME/bin:$PATH"
fi
