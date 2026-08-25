# ai-sandbox

[中文](README.md) | English

Run Claude Code and Codex CLI on macOS using [Apple container](https://github.com/apple/container).
The default `aibox` workflow creates a short-lived Linux container for one explicitly mounted
project. `aibox dev` provides a separate persistent Linux development machine with the host home
mounted read-write.

This is an independent, unofficial project. It is not affiliated with, endorsed by, or supported
by Apple, Anthropic, OpenAI, Eclipse Adoptium, the Apache Software Foundation, or the go-gost
project. Product names and trademarks belong to their respective owners. You are responsible for
complying with each service's terms and with applicable law.

## Features

- One command to open a shell, Claude Code, or Codex CLI in an ephemeral container.
- A persistent `container machine` development environment for working across projects and keeping
  installed system packages between restarts.
- The selected project is mounted at `/workspace/<project-name>`; unrelated host directories are
  not mounted automatically.
- Separate persistent Claude and Codex state, without reusing the host's own CLI profiles.
- Multiple projects and containers can run at the same time, with list, enter, log, stop, and
  cleanup commands.
- Optional HTTP, HTTPS, SOCKS5, or SOCKS5H upstream proxy with an IPv4/IPv6 egress firewall that blocks bypass traffic.
- Runtime timezone and locale selection.
- `ai-ipcheck` is installed by default, providing the `ipcheck` network-diagnostics command.
- Optional JDK 8 and Maven from local archives; an empty `third_party/` directory still builds the
  core AI CLI image.
- Pinned Claude Code and Codex CLI versions with an interactive update command.
- `aibox clip install` enables a clipboard image bridge so Claude Code inside the sandbox can
  paste images from the macOS clipboard with Ctrl+V.

## Compatibility

- An Apple silicon Mac.
- macOS 26. Apple does not support older macOS releases for `container`.
- [Apple container](https://github.com/apple/container) installed and available as `container`.
  CLI 1.0.0 is the currently tested version. This project does not use Docker Desktop or the
  `docker` command.
- Bash 3.2 or later for `ai-box`; zsh and Bash completion are supported.
- Enough memory and disk for the images, machine disk, caches, and projects. Ephemeral containers
  and the development machine request `8192M` by default through `MEMORY` and `DEV_MEMORY`.

The image is Linux/arm64. Any optional binary or archive placed in `third_party/` must match that
platform.

## Install

### 1. Install Apple container

Apple container is a hard prerequisite for this project, not an alias for Docker Desktop. It is
Apple's Swift-based tool for running Linux containers as lightweight virtual machines on Apple
silicon Macs, using OCI-compatible images.

- Official repository: [apple/container](https://github.com/apple/container)
- Signed installer packages: [apple/container Releases](https://github.com/apple/container/releases)
- Hardware: Apple silicon. Intel Macs are not supported.
- Operating system: macOS 26. Apple explicitly does not support older releases and generally does
  not address issues that cannot be reproduced on macOS 26.

Check the host before installing:

```bash
uname -m                 # expected: arm64
sw_vers -productVersion  # expected: 26.x
```

Follow Apple's current installation method:

1. Open the [Releases page](https://github.com/apple/container/releases) and download the latest
   Apple-signed installer package.
2. Double-click the `.pkg` and follow the installer. Enter an administrator password when prompted
   so it can install files under `/usr/local`.
3. Start the system service and verify the CLI:

```bash
container system start
container --version
container list
```

`container list` should return successfully even when no containers are running. Once installed,
the later `aibox start` command is a wrapper around `container system start`.

To upgrade an existing installation using Apple's installed helper:

```bash
container system stop
/usr/local/bin/update-container.sh
container system start
```

Installation, upgrade, and uninstall behavior may change between Apple container releases. Treat
the [official installation instructions](https://github.com/apple/container#initial-install) as
authoritative.

### 2. Install ai-sandbox

Clone this repository to any location. From the clone directory, create an `aibox` symlink in a
directory on your `PATH`:

```bash
cd /absolute/path/to/ai-sandbox
repo="$(pwd -P)"
mkdir -p "$HOME/.local/bin"
ln -s "$repo/ai-box" "$HOME/.local/bin/aibox"
```

Add `$HOME/.local/bin` to `PATH` if necessary. The launcher resolves the repository from its own
real path, so the clone does not need to be at `~/ai-sandbox`.

Optional shell completion:

```bash
# Add the corresponding absolute path to ~/.zshrc or ~/.bashrc:
source /absolute/path/to/ai-sandbox/ai-box-completion.sh
```

## Quick Start

```bash
# Start Apple container and build the ephemeral image.
aibox start
aibox build

# Run from any project directory.
cd /path/to/project
aibox            # shell
aibox cc         # Claude Code; "claude" is also accepted
aibox codex      # Codex CLI

# Or enter the persistent, project-independent development machine.
aibox dev build  # required before the first development-machine launch
aibox dev
```

When a tool exits, the launcher leaves you in the container shell. Run `exit` to remove that
container. Changes made under the mounted project, credentials, and caches remain on the host.

To use API keys, other custom environment variables, or runtime settings, create a local
configuration file:

```bash
cd /absolute/path/to/ai-sandbox
cp aibox.conf.example aibox.conf
chmod 600 aibox.conf
```

`aibox.conf` can contain API keys, proxy credentials, and other secrets. It is excluded by both
`.gitignore` and `.dockerignore`; do not commit it or paste its contents into issues or logs.

## Configuration

All runtime settings are optional:

```sh
AIBOX_PROXY="" # Direct connection, or http(s):// / socks5(h):// URL
AIBOX_TZ=""    # Follow the host, or an IANA name such as Asia/Shanghai
AIBOX_LANG=""  # Follow the host, or a generated locale such as en_US.UTF-8
AIBOX_ENV_VARS=( # Custom environment variables passed into the container
  'EXAMPLE_NAME=value with spaces'
)
```

`ai-box` **sources `aibox.conf` as shell code on the host**. It is not a passive data file and can
run arbitrary commands with your user permissions. Use only a configuration you created or fully
reviewed. Keep proxy passwords and other secrets out of examples, issues, and logs.

For each of the three scalar settings, only a **non-empty** exported environment variable overrides
a non-empty file value. An empty environment variable cannot clear a non-empty value in
`aibox.conf`.

The exact precedence is:

- `AIBOX_PROXY`: non-empty environment value, then non-empty file value. If `aibox.conf` does not
  exist, legacy `FIXED_SOCKS_*` variables are accepted next; otherwise the connection is direct.
  An existing file with an empty `AIBOX_PROXY` disables that legacy fallback.
- `AIBOX_TZ`: non-empty environment value, non-empty file value, detected host timezone, then the
  image default (`UTC`).
- `AIBOX_LANG`: non-empty environment value, non-empty file value, non-empty host `LANG`, then the
  image default (`C.UTF-8`).

For a one-off override, use a non-empty value such as `AIBOX_TZ=UTC aibox`. A requested locale must
already be listed in `LOCALE_GEN` in the Dockerfile; otherwise the entrypoint falls back to
`C.UTF-8` and prints a warning.

`AIBOX_ENV_VARS` is read only from `aibox.conf`. It is a Bash array declared in that file, and each
item is one complete `NAME=value` entry:

```bash
AIBOX_ENV_VARS=(
  'EMPTY_VALUE='
  'TEXT_VALUE=value with spaces'
  'ENDPOINT=https://example.invalid/path?a=b'
)
```

Names must match `[A-Za-z_][A-Za-z0-9_]*` and must not start with the internally reserved `AIBOX_`
prefix. `ai-box` splits each entry at its first `=`, so a value may be empty, contain spaces, or
contain additional equals signs, but it must stay on one line. Values containing a carriage return
(CR) or line feed (LF) are rejected. The array follows Bash quoting and expansion rules:
single-quoted text is literal, while variables, command substitutions, and other expansions inside
double quotes are evaluated when the file is sourced. Single quotes are usually the safer choice
for secrets.

Custom values are not placed in the `container` CLI argument list, but this is not secret isolation.
They are written briefly to a host-side temporary env file with mode `0600`. Ephemeral mode mounts
it read-only and imports it only after dropping to `node`; dev mode passes it only to the ordinary
user login process through `machine run --env-file`. The root system-configuration step uses a
separate file containing only the resolved `AIBOX_PROXY` and `AIBOX_TZ` values to refresh the proxy
service and system timezone, so custom `PATH`, `LD_PRELOAD`, or `BASH_ENV` never reach it. Files are
removed on normal exit and common termination signals, although a system
crash or forced `SIGKILL` can leave one behind. Values remain visible to user processes. They are not
exported into the host `ai-box` process environment, so custom names such as `PATH` and `HOME` do not
alter the host launcher environment. `ai-box` no longer implicitly forwards `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, or other host API keys; list every required variable explicitly.

## Optional `third_party/` Components

This repository does not track local third-party assets. They are ignored by Git because they can
be large and their redistribution terms and preferred download routes differ. Create `third_party/`
if it is absent and add only the components you need:

| Exact filename | Build result | Verified version | Upstream and license |
| --- | --- | --- | --- |
| `gost` | Installs the Linux/arm64 proxy bridge. Required only when `AIBOX_PROXY` is non-empty. | gost 3.2.6, Linux ARM64 | [go-gost releases](https://github.com/go-gost/gost/releases), MIT |
| `jdk8.tar.gz` | Extracts a Linux/arm64 JDK into `/opt/java/jdk8` and enables `java`/`javac`. | Eclipse Temurin 8u492-b09, Linux AArch64 JDK | [Eclipse Temurin 8](https://adoptium.net/temurin/releases/?version=8), GPLv2 with Classpath Exception plus bundled third-party notices |
| `maven.tar.gz` | Extracts Maven into `/opt/maven` and enables `mvn`. It can be installed independently, but cannot run without a compatible JDK. | Apache Maven 3.9.16 binary tarball | [Apache Maven downloads](https://maven.apache.org/download.cgi), Apache License 2.0 |

SHA-256 hashes of the assets used for the verified setup above:

```text
343c3e003996ca0437b9cc47dd1500cd0475ba09f5a5f17e50851854e06a1ca7  gost
3c2253b986909c20f79d6de7a0cb957f89c243df57615897836046e24d2e5257  jdk8.tar.gz
80ffca22aed9e8b9713a232f3394fd81d7f20322df75efdb2b047dbd3e3a23bb  maven.tar.gz
```

The filenames are exact, each component is detected independently, and unknown files are ignored.
With none of them present, `aibox build` produces the core image with Claude Code, Codex CLI, and
the standard shell tools. If a proxy is configured without `third_party/gost`, container startup
fails with an actionable error instead of silently using a direct connection.

Download assets from their upstream projects, verify their published checksums or signatures, and
review their licenses before use. Local assets are sent in the build context when present, but are
not committed by default. They avoid downloading those particular components during the build;
the base image, Debian packages, Python package, and npm CLIs can still require network access.

Changing any `third_party/` file requires `aibox build`.

## Network and Proxy Behavior

With `AIBOX_PROXY` set and `gost` installed, the path is:

```text
proxy-aware process
  -> HTTP_PROXY=http://127.0.0.1:8080
  -> gost (dedicated aibox-gost UID)
  -> configured HTTP(S)/SOCKS5(H) upstream
  -> destination
```

The entrypoint installs an IPv4 and IPv6 `OUTPUT` firewall in proxy mode. Ordinary processes may
only connect over loopback; only the dedicated `aibox-gost` UID may open external connections.
Software that ignores the proxy variables, uses raw sockets, or performs custom DNS cannot bypass
the proxy and instead fails to connect. This is a fail-closed kill switch, not transparent proxying,
so software without HTTP-proxy support still needs explicit local-proxy configuration.

If the firewall or gost fails to initialize, the user command is not started. The launcher grants
`CAP_NET_ADMIN` only for initialization; the entrypoint then removes the `node` sudo rule, clears
the capability bounding set, enables `no_new_privs`, and launches the CLI as `node`. Use `socks5h://`
when the upstream should resolve destination hostnames. Credentials are masked in the banner but
remain available inside the container, so masking is not secret isolation.

No host proxy application is required by this project. Direct mode is supported.

The firewall described above applies only to ephemeral containers. Dev mode refreshes a systemd
gost service inside the machine from the same upstream setting. Login shells and background tasks
use its stable `127.0.0.1:8080` endpoint, but deliberate direct connections are not blocked.

The image installs the third-party `ai-ipcheck` package from PyPI by default. Run it inside the
container with:

```bash
ipcheck
```

It reports network information such as IP, DNS, proxy, and timezone details. The tool comes from
the original [stormzhang/ipcheck](https://github.com/stormzhang/ipcheck) project; credit and thanks
go to its original author and maintainers. Refer to the upstream repository for its license and
usage documentation.

## Authentication

For API-key authentication, add the variables you need explicitly to your local `aibox.conf`:

```bash
AIBOX_ENV_VARS=(
  'ANTHROPIC_API_KEY=replace-with-your-key'
  'OPENAI_API_KEY=replace-with-your-key'
)
```

Only configure the keys you intend to use, then run `aibox cc` or `aibox codex`. Do not rely on
variables exported by your host shell; the launcher does not implicitly forward them.

For browser or subscription login, remove or comment out the corresponding API-key entry in
`AIBOX_ENV_VARS`, start the CLI, and follow its login flow. State is persisted under `creds/claude/`
and `creds/codex/` in the repository clone, not in the host's `~/.claude` or `~/.codex`. Protect
those directories and any secret-bearing `aibox.conf` as credentials, do not publish them, and
remove or back them up deliberately before deleting the clone.

This authentication model applies to the default ephemeral containers. `aibox dev` mounts the host
home read-write and therefore uses CLI configuration and login state from that home. The launcher
refreshes the machine's system timezone and local proxy service from `aibox.conf`, and injects
timezone, locale, and `AIBOX_ENV_VARS` settings into each dev login session.

## Security and Trust Boundary

Containers are ephemeral, but they are not a boundary for untrusted code. A process in the
container can access every path explicitly mounted by `ai-box`:

| Host path | Container path | Purpose |
| --- | --- | --- |
| Selected project | `/workspace/<project-name>` | Project files; edits immediately affect the host |
| `<repo>/creds/claude` and `<repo>/creds/codex` | `/home/node/.claude` and `/home/node/.codex` | Persistent authentication and tool state |
| `~/.m2/repository` | `/home/node/.m2/repository` | Maven artifacts shared with the host |
| `<repo>/cache/gradle` | `/home/node/.gradle` | Linux-specific Gradle cache |
| Launch-time snapshot of `<repo>/entrypoint.sh` | `/usr/local/bin/entrypoint.sh` | Read-only runtime entrypoint override |

User commands run as `node`. Direct-mode containers retain passwordless `sudo`; proxy-mode containers
remove sudo and capabilities after firewall initialization so container code cannot disable the
kill switch. Container code can
modify the mounted project and persistent state, read values configured through `AIBOX_ENV_VARS`,
access the network, and potentially alter mounted caches. Those values are not placed in the
`container` CLI arguments or exported into the host launcher environment. They are written briefly
to a mode-`0600` host-side temporary env file, mounted read-only, imported only after privilege
drop, removed when `ai-box` exits, and visible as environment variables to user processes. Review
project scripts and AI-generated commands
before running them. Container isolation reduces accidental host access; it does not make arbitrary
code trusted.

Claude groups project state by the container working-directory path. Two host directories with the
same basename map to the same `/workspace/<name>` and may share Claude project history or memory in
the persistent credential directory.

`aibox dev` has a different trust boundary. On first boot, Apple container provisions a user with
the host UID/GID and passwordless sudo, then mounts the entire host home read-write. The Linux root
filesystem persists across stops, but projects, credentials, SSH configuration, and other files in
the mounted home are real host data and can be modified by machine processes. The development
machine reads the same `aibox.conf`. A configured proxy refreshes a machine-local gost service
managed by systemd, and login sessions use its stable local HTTP endpoint; custom variables are
injected through a temporary mode-`0600` env file. Because the machine user has sudo and full
system control, this is a default proxy route, not the ephemeral container's fail-closed egress
boundary, and a process can deliberately bypass it. Use `dev` for trusted development workflows,
not for code that must be restricted to one host directory or forced through the proxy.

## Commands

```bash
# Open a new ephemeral container
aibox [/path/to/project]
aibox cc [/path/to/project]
aibox codex [/path/to/project]

# Persistent development machine (fixed name: aibox-dev)
aibox dev                     # create/start and enter; exit only closes this shell
aibox dev build [--no-cache]  # build only the development-machine image
aibox dev start               # create/start and refresh the proxy without a shell
aibox dev restart             # restart and refresh the proxy service
aibox dev exec <cmd> [args]   # run a command as the ordinary machine user
aibox dev update [cc|codex]   # update AI CLIs on the persistent system disk
aibox dev version [cc|codex]  # show versions actually installed in the machine
aibox dev set memory=8G cpus=4  # change resources; takes effect after restart
aibox dev status
aibox dev stop                # keep the persistent system disk
aibox dev logs [-f]
aibox dev delete              # confirm, then delete the machine and system disk; alias: rm

# Manage aibox containers
aibox list                      # alias: ls; add -a for stopped containers
aibox enter [number|project|container]
aibox logs <number|project|container> [-f]
aibox stop <number|project|container>
aibox stop --all
aibox clear                     # alias: prune

# Service, image, and CLI versions
aibox start
aibox build [--no-cache]      # build only the ephemeral-container image
aibox update [cc|codex]
aibox version
aibox status
aibox help

# Clipboard image bridge (host-side watcher; applies to both modes)
aibox clip install
aibox clip status
aibox clip restart
aibox clip uninstall
```

Every normal launch creates a separate `aibox-<project>-<time>-<launcher-pid>` container carrying a
`com.simpletang.ai-sandbox.managed=true` label. Management commands only recognize `aibox-*`, so
unrelated `ai-*` containers are never included in bulk stop or cleanup. Use the native `container`
commands to handle legacy `ai-*` containers left by an older release. `aibox enter` opens another
shell in an existing container; exiting that extra shell does not stop the original container.

The development machine lives in the separate `container machine` namespace and always uses the
name `aibox-dev`. Ordinary `aibox list`, `stop`, and `clear` commands never manage it. Running
`aibox dev` automatically boots a stopped machine. `aibox dev start` boots it and refreshes the
machine's system timezone and local proxy without opening a shell, while `restart` reboots it and
performs the same refresh. Locale and custom variables are session settings applied by bare
`aibox dev` and `dev exec`; timezone also updates `/etc/localtime` and `/etc/timezone`. `dev exec`
allocates an interactive TTY. Only `aibox dev delete` removes the persistent system disk.

## Clipboard Image Pasting

A terminal can only deliver **text** into the tty as simulated keystrokes; images never cross that
boundary. Pasting an image requires the running program to read the operating-system clipboard
itself, and the sandbox has neither X11/Wayland nor any route to the macOS pasteboard. Ctrl+V image
paste therefore does not work out of the box.

`aibox clip install` starts a launchd watcher on macOS. Whenever the clipboard holds an image, the
watcher writes it as a PNG into `~/.clipboard-bridge/`. An `xclip` shim baked into the image reads
that directory, so Ctrl+V behaves natively. No X server and no network ports are involved.

```bash
aibox clip install     # run once on macOS
# copy an image, then
aibox clip status      # should report an image is ready to paste
```

Both `aibox status` and `aibox dev status` include a clipboard-bridge line that distinguishes
not installed, running with an image ready, running with an empty clipboard, and a stale heartbeat
meaning the watcher died — so a broken bridge shows up in the ordinary status check.

Inside the sandbox press **Ctrl+V**, not ⌘V — the macOS terminal intercepts ⌘V as a text paste, so
it never reaches the container.

The bridge path differs per mode and `ai-box` injects `CLIP_BRIDGE_DIR` accordingly. `aibox dev`
already mounts the whole host home with `--home-mount rw`, so the path matches macOS exactly; the
ephemeral `aibox` mounts only the project directory, so `~/.clipboard-bridge` is additionally
mounted read-only at `/run/aibox/clipboard-bridge`. When the host side is not installed nothing is
mounted and the shim quietly reports no image.

The watcher mirrors **images only, never clipboard text**, so passwords copied from a password
manager are never written to disk. See [`clipboard-bridge/README.md`](clipboard-bridge/README.md)
for the mechanism, architecture diagram, and troubleshooting.

## Optional Java Support

Add `jdk8.tar.gz`, `maven.tar.gz`, or both as described above and rebuild. A Maven command requires
a JDK, and a Gradle wrapper also requires a compatible JDK:

```bash
mvn clean package
./gradlew build
```

Maven artifacts use the host's `~/.m2/repository`. Gradle uses `<repo>/cache/gradle` because a single
Gradle home should not be shared between macOS and Linux. Avoid simultaneous host and container
Maven builds that write the same artifact cache.

Maven and Gradle do not consistently honor `HTTP_PROXY`, so the entrypoint creates their proxy
settings when a proxy is active. Direct Java connections are rejected by the proxy-mode firewall;
add JVM proxy properties explicitly when needed, for example:

```bash
java -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=8080 \
     -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=8080 -jar app.jar
```

## Updates and Rebuilds

`aibox update`, optionally limited to `cc` or `codex`, checks the npm mirror, shows the pinned and
latest versions, asks for confirmation, and updates the Dockerfile ARG. It then performs an
**incremental update** via `Dockerfile.update`: a single `npm install` layer stacked on top of the
existing image, downloading only the packages that actually changed. This skips the apt/locale/pip
layers entirely and does not depend on the builder's layer cache (which is lost whenever the builder
container is deleted and recreated, turning a full rebuild into a re-download of every dependency).
If the local image is missing or the incremental build fails, the command offers a full rebuild
instead. Existing containers keep their old image; new ephemeral containers use the updated one.

The development machine has its own writable system disk and does not change when its base image is
updated. `aibox dev update [cc|codex]` upgrades the AI CLIs directly on that disk, using the local
dev gost service when configured, and does not change the Dockerfile pins. To rebuild from the
latest image recipe, back up any system-disk data you need. Run `aibox build` first when the base
image changed, then run `aibox dev build`. Delete the old machine with `aibox dev delete`, and run
`aibox dev` to recreate it. Deleting the machine does not delete files in the mounted host home.

Each incremental update adds a new layer while older CLI files remain in lower layers, so the image
grows slowly over repeated updates. Run `aibox build` occasionally to squash it — `update` keeps the
Dockerfile pins in sync, so a full rebuild reproduces the same versions.

Run `aibox build` after changing `Dockerfile`, `network-lockdown.sh`, `LOCALE_GEN`, a pinned CLI
version, or a recognized `third_party/` asset. Run `aibox dev build` after changing `Dockerfile.dev`,
a `dev-*.sh` helper, or a development-machine service. Run both in that order when the development
image must inherit a newly rebuilt base image. An existing development machine does not receive new
dev helpers until it is deleted and recreated. Changes to `aibox.conf` and the symlinked `ai-box`
launcher apply on the next invocation. Ordinary `entrypoint.sh` edits are mounted as a launch-time
snapshot, but changes involving image tools, users, or privileges still require a full rebuild.

After upgrading to the firewall-enabled design, run `aibox build` at least once. An older image does
not contain iptables, the dedicated gost user, or the root initialization entrypoint and cannot be
upgraded by the runtime entrypoint snapshot alone.

`aibox version` and the version line in `aibox status` read the pins declared in the current
Dockerfile. They do not inspect an already-built image, so they can differ from that image until a
successful rebuild.

## Troubleshooting

| Symptom | Check or action |
| --- | --- |
| `container` is unavailable | Confirm macOS 26, Apple silicon, and the Apple container installation. This project does not use Docker. |
| The service or image is missing | Run `aibox status`, then `aibox start` and `aibox build`. |
| `aibox dev` reports a missing machine image | Run `aibox dev build`; if its base image is missing, run `aibox build` first. |
| The first `aibox dev` after a Mac restart reports `Failed to connect to bus` | Update the host-side `ai-box`; it waits for the machine's systemd manager before applying system settings, without requiring machine deletion. |
| Build dependency downloads fail | The build still needs access to the base-image registry, Debian/PyPI, and npm sources. Fix that path or retry; local `third_party/` assets only replace their own downloads. |
| A configured proxy fails immediately | Confirm that `third_party/gost` existed when the image was built, is Linux/arm64, and is executable; then rebuild. Check `aibox logs <target>`. |
| Lockdown components are missing or firewall initialization fails | Run a full `aibox build`. If it still fails, confirm Apple container accepted the launcher's `CAP_NET_ADMIN` capability. |
| A SOCKS proxy cannot resolve names | Try a `socks5h://` URL so the proxy resolves hostnames. |
| A locale falls back to `C.UTF-8` | Add it to `LOCALE_GEN` in the Dockerfile and rebuild. |
| A long CLI session becomes slow or is killed | Check host memory pressure; the container requests `8192M`. Compact or restart long Claude sessions when appropriate. |
| Two projects share Claude state | Give their mounted directories different basenames. |
| Apple container's builder is stuck | Follow Apple container diagnostics; recreating the builder may discard builder state and should be a deliberate last resort. |
| The mounted project directory is empty inside the container | Apple container's single-file mounts also share the file's parent directory; when that parent is itself the source of another mount (e.g. `entrypoint.sh` while mounting the sandbox repo as the project), that mount silently comes up empty. `ai-box` avoids this by mounting a launch-time snapshot of `entrypoint.sh`; if it still happens, update the host-side `ai-box` or restart the container service. |

The startup banner reports the effective project, mount, proxy source, timezone, locale, and IPv6
status. It is the first place to check after changing configuration.

## Development, Contributions, and Security Reports

Keep changes focused and preserve compatibility with macOS Bash 3.2. Run the portable smoke suite:

```bash
./tests/smoke.sh
```

CI runs the smoke checks on macOS and Ubuntu. A real image build and interactive runtime test still
require a compatible Apple silicon Mac with Apple container. For shell changes, `bash -n` and
ShellCheck are also useful.

Issues and pull requests are welcome. Never attach `aibox.conf`, API keys, proxy URLs containing
credentials, `creds/`, or unredacted logs. For a vulnerability, use GitHub's private **Security ->
Report a vulnerability** flow. If private reporting is unavailable, contact the maintainer privately
through the contact method on their GitHub profile rather than opening a public issue.

## Uninstall

1. Stop active aibox containers with `aibox stop --all`, then delete the persistent development
   machine and its system disk with `aibox dev delete` if it exists.
2. Remove the `aibox` symlink from `$HOME/.local/bin` and remove the completion line from your shell
   startup file.
3. Delete the `ai-sandbox:latest` and `ai-sandbox-dev:latest` images with Apple container's
   image-management command if they are no longer needed.
4. Delete the clone only after deciding whether to keep `creds/`, `cache/gradle`, and local
   `third_party/` assets. The clone may contain authentication secrets even though Git ignores them.

The shared host Maven repository at `~/.m2/repository` is not owned exclusively by this project and
is not removed as part of uninstalling it.

## License and Upstream Software

The original scripts and documentation in this repository are licensed under the [MIT License](LICENSE).
That license does not relicense Apple container, the base Node/Debian image, Claude Code, Codex CLI,
`ai-ipcheck`, `gost`, Eclipse Temurin, Apache Maven, or their dependencies. Their own licenses and
terms continue to apply:

- [Apple container](https://github.com/apple/container)
- [Node official container image](https://hub.docker.com/_/node) and [Debian copyright information](https://www.debian.org/legal/licenses/)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code/overview)
- [OpenAI Codex CLI](https://github.com/openai/codex)
- [`ai-ipcheck`](https://github.com/stormzhang/ipcheck)
- [`gost`](https://github.com/go-gost/gost), Eclipse Temurin, and Apache Maven as listed in the optional-components table

Review the version pins in the Dockerfile and the license or notice files included with every binary
you choose to add to `third_party/`.
