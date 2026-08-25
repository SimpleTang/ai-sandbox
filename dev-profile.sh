# container machine mounts the host user's home at its matching machine path.
# Keep Claude's state with that user instead of the base image's ephemeral node user.
export CLAUDE_CONFIG_DIR="$HOME/.claude"

if [ -x /opt/java/jdk8/bin/java ]; then
    export JAVA_HOME=/opt/java/jdk8
    export PATH="$JAVA_HOME/bin:$PATH"
fi
if [ -x /opt/maven/bin/mvn ]; then
    export MAVEN_HOME=/opt/maven
    export PATH="$MAVEN_HOME/bin:$PATH"
fi
