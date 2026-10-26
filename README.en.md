# ai-sandbox

[中文](README.md) | English

Run Claude Code and Codex CLI on macOS using [Apple container](https://github.com/apple/container).
By default, `aibox` enters a persistent container built on `container machine`: the host home is
mounted read-write at its original path, and software and system settings installed inside it are
kept on a persistent system disk. `aibox tmp` instead creates a short-lived temporary container that
mounts only the selected project and a few explicitly persisted directories.

Changes and upgrade notes for each version are in [CHANGELOG.md](CHANGELOG.md) (Chinese, with an
English summary per release); release archives are on the
[Releases](https://github.com/SimpleTang/ai-sandbox/releases) page.

This is an independent, unofficial project. It is not affiliated with, endorsed by, or supported
by Apple, Anthropic, OpenAI, Eclipse Adoptium, the Apache Software Foundation, or the go-gost
project. Product names and trademarks belong to their respective owners. You are responsible for
complying with each service's terms and with applicable law.

## Features

- One command to open a shell, Claude Code, or Codex CLI.
- A persistent container (fixed name `aibox-dev`) for working across projects in your home
  directory and keeping installed system packages between restarts. The container service is
  started automatically when needed.
- `aibox tmp` temporary containers: one `--rm` container per terminal session, with only the
  selected project mounted at `/workspace/<project-name>`; unrelated host directories are not
  mounted automatically.
- Claude and Codex login state lives in the host's `~/.aibox/`, shared by both container types and
  kept apart from the Mac's own `~/.claude` and `~/.codex`.
- Multiple temporary containers can run at the same time, with list, enter, log, stop, and cleanup
  commands.
- Optional HTTP, HTTPS, SOCKS5, or SOCKS5H upstream proxy; temporary containers add an IPv4/IPv6
  egress firewall that blocks bypass traffic.
- Runtime timezone and locale selection.
- `ai-ipcheck` is installed by default, providing the `ipcheck` network-diagnostics command.
- A general-purpose AI CLI sandbox: no JDK, Maven, or other language toolchains are baked in;
  install what you need inside the persistent container, whose system disk is kept.
- Configuration, login state, and optional assets all live in `~/.aibox/`; the program
  directory (the git clone) is treated as read-only and replaceable.
- Pinned Claude Code and Codex CLI versions with interactive update commands.
- `aibox clip install` enables a clipboard image bridge so Claude Code inside the sandbox can
  paste images from the macOS clipboard with Ctrl+V.

## Compatibility

- An Apple silicon Mac.
- macOS 26. Apple does not support older macOS releases for `container`.
- [Apple container](https://github.com/apple/container) installed and available as `container`.
  Version 1.6.0 is the currently verified version and 1.0.0 is the minimum. This project does not
  use Docker Desktop or the `docker` command.
- Bash 3.2 or later for `ai-box`; zsh and Bash completion are supported.
- Enough memory and disk for the images, machine disk, and projects. Both container types request
  `8192M` of memory by default and leave the CPU count to Apple container (4 for temporary
  containers, half the host's cores for the persistent container). Change them with
  `AIBOX_MEMORY` / `AIBOX_CPUS` in `aibox.conf` (see [Configuration](#configuration)).

`aibox` runs only on macOS and only as an ordinary user. In Linux (including inside the persistent
container) or under `sudo`/root it exits with an error, because `$HOME` there is not the Mac user's
home and reading or writing `~/.aibox` would put user data in the wrong place. `aibox help` and
`aibox --version` work everywhere.

The image is Linux/arm64. A `gost` binary placed in `~/.aibox/third_party/` must match that
platform.

## Install

### Option 1: Homebrew (recommended)

```bash
brew install simpletang/tap/aibox
aibox setup
```

`aibox setup` is the setup wizard described below. The formula does not declare Apple container as
a dependency: the wizard checks for it and guides you to the version this project has verified,
and it does not clash with an existing installation from Apple's `.pkg`. Upgrade with
`brew upgrade aibox`.

### Option 2: git clone and the setup wizard

```bash
git clone https://github.com/SimpleTang/ai-sandbox.git
cd ai-sandbox
./setup.sh
```

The wizard checks and completes the steps below. Each step inspects the current state first and
skips what is already done, so it is safe to interrupt and rerun. Choices use the arrow keys and
Enter (yes/no questions also take y or n); time zone, language, memory and CPU list common values,
and the last item, 手动输入… (manual entry), accepts anything else:

1. Check the Mac: Apple silicon and macOS 26, and show the host's memory and CPU count. With less
   than 16G of memory it suggests a smaller container memory in step 5.
2. Install Apple container: optionally download the official installer for the verified version
   (currently 1.6.0), verify Apple's signature, and open the system installer, or just open the
   download page. An existing installation is version-checked: below the minimum it asks you to
   upgrade; newer than the verified version it only warns that the version is unverified.
3. Start the container service. The first start downloads Apple's recommended default Linux kernel.
4. Install the `aibox` command: for a git clone, symlink it into `~/.local/bin` and optionally add
   that directory to `PATH`; for Homebrew, brew provides the command and the wizard only checks
   that an old `~/.local/bin/aibox` from a git clone does not shadow it, offering to remove it.
   Then enable completion (in `~/.zshrc`, or `~/.bash_profile` for bash; Homebrew installs use the
   version-independent `opt/aibox` path). Existing completion lines pointing elsewhere are
   commented out, not deleted.
5. Create `~/.aibox/aibox.conf` (mode `600`): proxy, timezone, locale, resources (memory and CPUs,
   capped at what the Mac has), and authentication (account login inside the container, or API
   keys). For a proxy it validates the URL, replaces addresses
   such as `127.0.0.1`, which a container cannot reach, with the host's address on the container
   network, can download gost and verify the SHA-256 recorded below, and can test whether the proxy
   reaches the Claude API. An existing configuration is kept by default; changing it backs up the
   old file and preserves `AIBOX_ENV_VARS` entries unrelated to authentication. When the resources
   change and the persistent container already exists, it offers to apply them with `aibox set`
   (effective after `aibox restart`).
6. Migrate and clean up old data: if the old release left login state and settings behind, choose
   the persistent container's, the temporary container's, or a merge (see Authentication). An
   `aibox.conf` and `third_party/gost` left in the program directory by an older release are moved
   to `~/.aibox/` automatically right after step 1 (see
   [User Data Directory](#user-data-directory)). Old `jdk8.tar.gz` / `maven.tar.gz` archives and
   the Gradle cache (`~/.aibox/cache/gradle` or `cache/gradle` in the program directory) are no
   longer used; the wizard lists them with their sizes and offers to delete them (default: keep).
7. Build images: both `ai-sandbox:latest` (the base image, used by temporary containers) and
   `ai-sandbox-dev:latest` (the persistent-container image) are required; if either is missing,
   the wizard runs `aibox build`, which builds them in that order.
8. Optionally enable clipboard image pasting.

At the end the wizard suggests the next commands: `aibox cc` for Claude Code in the persistent
container, or `aibox tmp cc` for a temporary container. After installation, run `aibox setup` at
any time to adjust the configuration. `aibox setup --check` only reports the state of each step and
changes nothing, which helps find a missing piece.

Use the manual steps below if you prefer to control each step, or if the wizard fails in your
environment.

### Manual installation

#### 1. Install Apple container

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

1. Open the [Releases page](https://github.com/apple/container/releases) and download the
   Apple-signed installer package (`container-<version>-installer-signed.pkg`). This project is
   currently verified on 1.6.0; newer versions usually work, and `aibox status` marks them as
   unverified.
2. Double-click the `.pkg` and follow the installer. Enter an administrator password when prompted
   so it can install files under `/usr/local`.
3. Start the system service and verify the CLI:

```bash
container system start
container --version
container list
```

`container list` should return successfully even when no containers are running. Afterwards, the
commands that enter the persistent container (`aibox`, `aibox cc`, `aibox start`, and so on) run
`container system start` automatically when the service is not running. Temporary containers and
`aibox build` do not start the service.

To upgrade an existing installation, use Apple's installed helper. Passing `-v` with the version
this project has verified is recommended; without arguments it installs the latest release.
Upgrading stops all temporary and persistent containers and asks for an administrator password:

```bash
container system stop
/usr/local/bin/update-container.sh -v 1.6.0
container system start
```

Adding `-f` lets the same helper reinstall an older version (for example `-v 1.0.0 -f`). The first
line of `aibox status` shows the installed version next to the verified one.

Installation, upgrade, and uninstall behavior may change between Apple container releases. Treat
the [official installation instructions](https://github.com/apple/container#initial-install) as
authoritative.

#### 2. Install ai-sandbox

Clone this repository to any location. From the clone directory, create an `aibox` symlink in a
directory on your `PATH`:

```bash
cd /absolute/path/to/ai-sandbox
repo="$(pwd -P)"
mkdir -p "$HOME/.local/bin"
ln -s "$repo/ai-box" "$HOME/.local/bin/aibox"
```

Add `$HOME/.local/bin` to `PATH` if necessary. The launcher resolves the repository from its own
real path, so the clone does not need to be at `~/ai-sandbox`. The program directory is treated as
read-only; user data lives in `~/.aibox/` (see [User Data Directory](#user-data-directory)).

Optional shell completion:

```bash
# Add the corresponding absolute path to ~/.zshrc or ~/.bashrc:
source /absolute/path/to/ai-sandbox/ai-box-completion.sh
```

## Quick Start

The simplest path is `aibox setup` (or `./setup.sh` in the clone), which installs, configures, and
builds the images. Manually, make sure the container service is running, build the images, and
then run from a project directory:

```bash
aibox build      # builds the base image, then the persistent-container image; skip if the wizard did it

cd ~/your-project
aibox cc         # Claude Code in the persistent container ("claude" is also accepted); the first run creates it
aibox codex      # Codex CLI in the persistent container
aibox            # just a shell in the persistent container

aibox tmp cc     # use a throwaway temporary container that mounts only this project
```

Choosing between the two:

- **Persistent container** (`aibox`): for trusted day-to-day work. The whole host home is mounted
  read-write, and software and system settings installed inside it survive stops and restarts. The
  working directory must be inside the host home: an explicit path outside it is rejected with a
  suggestion to use `aibox tmp`, and if the current directory is outside it, `aibox` opens your
  home directory instead and prints a notice. With `cc` or `codex`, you stay in the machine shell
  when the tool exits; `exit` leaves that shell but does not stop the persistent container (use
  `aibox stop` for that). Once the machine caches more than 50,000 host files, it releases the
  cache automatically, so a large walk cannot exhaust the Mac's file handles (see
  Troubleshooting).
- **Temporary container** (`aibox tmp`): for code you do not fully trust. Only the project and a
  few explicitly persisted directories are mounted, and proxy mode adds a fail-closed egress
  firewall. With `cc` or `codex`, you stay in the container shell when the tool exits; run `exit`
  again to remove the container. Changes made under the mounted project and login state
  remain on the host. Closing the terminal tab or dropping the SSH session stops the container.
  When the mount contains the whole home directory (running in `~`, or mounting `/Users` or `/`),
  the working directory becomes the empty `~/.aibox/home-workdir` while the mount stays under
  `/workspace/<project>`, and `aibox tmp cc` passes `--add-dir /workspace/<project>` to Claude
  Code; see Troubleshooting for why.

To use API keys, other custom environment variables, or runtime settings, run `aibox setup` to
create the configuration interactively, or create a local configuration file by hand:

```bash
cd /absolute/path/to/ai-sandbox
mkdir -p ~/.aibox
cp aibox.conf.example ~/.aibox/aibox.conf
chmod 600 ~/.aibox/aibox.conf
# edit ~/.aibox/aibox.conf, then rerun aibox; no image rebuild is needed
```

`aibox.conf` can contain API keys, proxy credentials, and other secrets. It lives outside the
program directory, so it never enters Git or the image build context; do not paste its contents
into issues or logs.

## User Data Directory

The program directory (the git clone or a Homebrew installation) holds only program files and is
treated as read-only and replaceable. Configuration, login state, and optional assets live in the
host's `~/.aibox/` (mode `700`):

| Path | Contents |
| --- | --- |
| `claude/`, `codex/` | Claude / Codex login state and settings, shared by both container types (see Authentication) |
| `aibox.conf` | Runtime configuration, written by `aibox setup` with mode `600` |
| `third_party/` | Optional `gost` (see [Optional `third_party/` Components](#optional-third_party-components)) |
| `versions.env` | CLI versions confirmed by `aibox tmp update` (see [Updates and Rebuilds](#updates-and-rebuilds)) |
| `machine/` | Helper scripts staged before each persistent-container start; maintained by the launcher |
| `clipboard/` | Copy of the clipboard watcher made by `aibox clip install` |
| `.migrated`, `legacy/` | Completion marker and backups of the old login-state migration (see Authentication) |

When upgrading from a release that kept these files in the program directory, the first run of an
`aibox` command or the setup wizard moves them automatically (the read-only `help`, `--version`,
and `setup --check` do not). Files already present at the new location are never overwritten:

- `<program dir>/aibox.conf` moves to `~/.aibox/aibox.conf`, and a symlink to the new location is
  left behind, so editing the old path still works. If both exist with different contents, the old
  file is no longer read and every run prints a notice; delete it once you no longer need it.
- `<program dir>/third_party/gost` moves to `~/.aibox/third_party/gost`. If both exist, the copy
  in `~/.aibox` is the one in use; the old one is ignored and each run prints a notice until you
  delete it.
- Old `jdk8.tar.gz` / `maven.tar.gz` archives and the Gradle cache are no longer moved;
  `aibox setup` offers to delete them.
- A `Dockerfile` edited by the old `aibox tmp update`: if the only local changes to the git
  clone's `Dockerfile` are the `ARG CLAUDE_CODE_VERSION=` and `ARG CODEX_VERSION=` lines, those
  versions are recorded in `~/.aibox/versions.env` and the `Dockerfile` is restored with git, so
  `git pull` no longer conflicts on it. Any other local `Dockerfile` edits are left untouched.

## Configuration

All runtime settings are optional and apply to both container types:

```sh
AIBOX_PROXY="" # Direct connection, or http(s):// / socks5(h):// URL
AIBOX_TZ=""    # Follow the host, or an IANA name such as Asia/Shanghai
AIBOX_LANG=""  # Follow the host, or a generated locale such as en_US.UTF-8
AIBOX_MEMORY="" # Container memory such as 16G; empty means 8192M
AIBOX_CPUS=""   # Container CPU count; empty leaves it to Apple container
AIBOX_ENV_VARS=( # Custom environment variables passed into the container
  'EXAMPLE_NAME=value with spaces'
)
```

`ai-box` **sources `aibox.conf` as shell code on the host**. It is not a passive data file and can
run arbitrary commands with your user permissions. Use only a configuration you created or fully
reviewed. Keep proxy passwords and other secrets out of examples, issues, and logs.

For each scalar setting, only a **non-empty** exported environment variable overrides
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
- `AIBOX_MEMORY`: non-empty environment value, non-empty file value, then `8192M`.
- `AIBOX_CPUS`: non-empty environment value, non-empty file value, then Apple container's default
  (4 for temporary containers, half the host's cores for the persistent container).

For a one-off override, use a non-empty value such as `AIBOX_TZ=UTC aibox`. A requested locale must
already be listed in `LOCALE_GEN` in the Dockerfile; otherwise the container falls back to
`C.UTF-8` and prints a warning.

When the resource settings take effect:

- Temporary containers use `AIBOX_MEMORY` / `AIBOX_CPUS` on every start; `AIBOX_MEMORY=16G aibox
  tmp` affects only that run.
- The persistent container uses them only when it is first created. After that its resources are
  part of the machine's own configuration: change them with `aibox set memory=16G cpus=6`, then
  `aibox restart`. `aibox setup` offers to do this when you change the resources there, and
  `aibox status` shows both the configured values and the machine's actual ones.
- Memory needs an `M` or `G` suffix (`8G`, `4096M`) and the CPU count must be a positive integer;
  `aibox` refuses to start a container when either is malformed. macOS allocates VM memory on
  demand, so a larger value does not reserve host memory up front.
- Inside an Apple container VM, `nproc` reports one more CPU than requested (`--cpus 2` shows 3);
  that is Apple container's own behavior.

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
They are written briefly to a host-side temporary env file with mode `0600`. Temporary containers
mount it read-only and import it only after dropping to `node`; the persistent container passes it
only to the ordinary user login process through `machine run --env-file`. The persistent container's
root system-configuration step uses a separate file containing only the resolved `AIBOX_PROXY` and
`AIBOX_TZ` values plus the login-state directory and the helper staging directory
`~/.aibox/machine`, to sync helper scripts and refresh the proxy service and system timezone, so
custom `PATH`, `LD_PRELOAD`, or `BASH_ENV` never reach it. Files are removed on normal exit and
common termination signals, although a system crash or forced `SIGKILL` can leave one behind. Values
remain visible to user processes. They are not exported into the host `ai-box` process environment,
so custom names such as `PATH` and `HOME` do not alter the host launcher environment. `ai-box` no
longer implicitly forwards `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or other host API keys; list every
required variable explicitly.

## Optional `third_party/` Components

Local third-party assets are not part of this repository. The build recognizes a single one in
`~/.aibox/third_party/` (create it if it is absent); `aibox setup` can download and verify it for
you. The `jdk8.tar.gz` and `maven.tar.gz` archives supported by older releases are no longer
installed.

| Exact filename | Build result | Verified version | Upstream and license |
| --- | --- | --- | --- |
| `gost` | Installs the Linux/arm64 proxy bridge. Required only when `AIBOX_PROXY` is non-empty. | gost 3.2.6, Linux ARM64 | [go-gost releases](https://github.com/go-gost/gost/releases), MIT |

SHA-256 of the verified binary:

```text
343c3e003996ca0437b9cc47dd1500cd0475ba09f5a5f17e50851854e06a1ca7  gost
```

The filename is exact and unknown files are ignored. Without it (or no `~/.aibox/third_party/` at all), `aibox build` produces the core
image with Claude Code, Codex CLI, and the standard shell tools. If a proxy is configured without
gost, container startup fails with an actionable error instead of silently using a direct
connection.

When adding it by hand, download it from the upstream project, verify the published checksum, and
review its license. For each build, `ai-box` assembles a temporary build context: program files are
copied from the program directory according to the `.dockerignore` allowlist, and `third_party/`
receives only `~/.aibox/third_party/gost`. The temporary directory is removed afterwards, so
nothing else from the program directory or `~/.aibox` (configuration, login state) enters the
build. The base image, Debian packages, Python package, and npm CLIs still require network access.

An existing persistent container picks up `~/.aibox/third_party/gost` on every start, wherever the
program directory is. Temporary containers need `aibox build` to use a new or replaced gost.

## Network and Proxy Behavior

In a temporary container with `AIBOX_PROXY` set and `gost` installed, the path is:

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

The firewall described above applies only to temporary containers. The persistent container
refreshes a systemd gost service inside the machine from the same upstream setting. Login shells
and background tasks use its stable `127.0.0.1:8080` endpoint, but deliberate direct connections
are not blocked.

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

For API-key authentication, add the variables you need explicitly to `~/.aibox/aibox.conf`:

```bash
AIBOX_ENV_VARS=(
  'ANTHROPIC_API_KEY=replace-with-your-key'
  'OPENAI_API_KEY=replace-with-your-key'
)
```

Only configure the keys you intend to use, then run `aibox cc` or `aibox codex` (or `aibox tmp cc`
/ `aibox tmp codex`). Do not rely on variables exported by your host shell; the launcher does not
implicitly forward them.

For browser or subscription login, remove or comment out the corresponding API-key entry in
`AIBOX_ENV_VARS`, start the CLI, and follow its login flow. State is persisted in the host's
`~/.aibox/claude/` and `~/.aibox/codex/` (`~/.aibox` has mode `700`), shared by both container
types, so logging in once in either is enough. It is kept apart from the Mac's own `~/.claude` and
`~/.codex`. Temporary containers mount these directories at `/home/node/.claude` and
`/home/node/.codex`. In the persistent container the ordinary user's `$HOME` is `/home/<user>` on
the machine's own system disk, while the host home is mounted at its original path; on every start
the launcher records the host-side path in `/etc/aibox/state-dir` inside the machine, and the login
profile points `CLAUDE_CONFIG_DIR` and `CODEX_HOME` at the host's `~/.aibox/claude` and
`~/.aibox/codex`. Protect these directories and any secret-bearing `aibox.conf` as credentials and
do not publish them.

Claude keys project state by the absolute working-directory path: `/workspace/<project-name>` in a
temporary container and the project's original host path in the persistent container. Session
history and project memory for the same project are therefore not shared between the two.

Upgrading from an older release: the old release kept Claude/Codex state in two places. Temporary
containers used `creds/claude/` and `creds/codex/` inside the clone; the persistent machine used the
machine user's own `/home/<user>/.claude` and `.codex` on its system disk, including `CLAUDE.md`,
`settings.json`, plugins, project memory, and session history. The first launch of either container
with the new release, `aibox setup`, or `aibox migrate` detects this data:

- If both exist, you choose: the persistent container's, the temporary container's, or a merge (the
  default). A merge uses the persistent container's state as the base and adds files only the
  temporary container had; session history from both is kept because it is keyed by working path;
  same-named files with different content (such as `CLAUDE.md`) are saved beside it as
  `*.from-tmp` for you to merge by hand. You can also postpone, in which case nothing starts.
- If only one exists, it is copied without asking.
- Old data is never deleted. After a successful copy, the machine's old directories are renamed to
  `.claude.pre-aibox-<time>` and replaced by links to `~/.aibox`, so entry points that bypass aibox
  no longer write to them; the clone's `creds/` moves to `~/.aibox/legacy/creds-<time>/`. Anything
  already in `~/.aibox` is first moved to `<name>.before-migrate-<time>`.
- Before migrating, aibox checks for Claude Code or Codex still running in the machine and for
  temporary containers started by the old release. They would keep writing to the old locations,
  so the migration only proceeds if you confirm. **Exit running sessions before migrating.**

Completion is recorded in `~/.aibox/.migrated` and you are not asked again. Delete the backups once
you have confirmed the new setup.

The persistent container reads the same `aibox.conf`. The launcher refreshes the machine's system
timezone and local proxy service from it, and injects timezone, locale, and `AIBOX_ENV_VARS`
settings into each login session.

## Security and Trust Boundary

Temporary containers are ephemeral, but they are not a boundary for untrusted code. A process in
the container can access every path explicitly mounted by `ai-box`:

| Host path | Container path | Purpose |
| --- | --- | --- |
| Selected project | `/workspace/<project-name>` | Project files; edits immediately affect the host |
| `~/.aibox/claude` and `~/.aibox/codex` | `/home/node/.claude` and `/home/node/.codex` | Persistent authentication and tool state, shared with the persistent container |
| Launch-time snapshot of `<program dir>/entrypoint.sh` (in a host temporary directory) | `/usr/local/bin/entrypoint.sh` | Read-only runtime entrypoint override |
| `~/.clipboard-bridge` (only when the clipboard bridge is enabled) | `/run/aibox/clipboard-bridge` | Read-only clipboard images |

User commands run as `node`. Direct-mode containers retain passwordless `sudo`; proxy-mode containers
remove sudo and capabilities after firewall initialization so container code cannot disable the
kill switch. Container code can
modify the mounted project and persistent state, read values configured through `AIBOX_ENV_VARS`,
and access the network. Those values are not placed in the
`container` CLI arguments or exported into the host launcher environment. They are written briefly
to a mode-`0600` host-side temporary env file, mounted read-only, imported only after privilege
drop, removed when `ai-box` exits, and visible as environment variables to user processes. Review
project scripts and AI-generated commands
before running them. Container isolation reduces accidental host access; it does not make arbitrary
code trusted.

Claude groups project state by the container working-directory path. Two host directories with the
same basename map to the same `/workspace/<name>` and may share Claude project history or memory in
the shared login-state directory.

The persistent container has a different trust boundary. On first boot, Apple container provisions
a user with the host UID/GID and passwordless sudo, then mounts the entire host home read-write at
its original path. The Linux root filesystem persists across stops, but projects, the `~/.aibox`
login state, the Mac's own `~/.claude` / `~/.codex`, SSH configuration, and other files in the
mounted home are real host data and can be modified by machine processes. The persistent container
reads the same `aibox.conf`. A configured proxy refreshes a machine-local gost service managed by
systemd, and login sessions use its stable local HTTP endpoint; custom variables are injected
through a temporary mode-`0600` env file. Because the machine user has sudo and full system
control, this is a default proxy route, not the temporary container's fail-closed egress boundary,
and a process can deliberately bypass it. Use the persistent container for trusted development
workflows; use `aibox tmp` for code that must be restricted to one host directory or forced
through the proxy.

## Commands

```bash
# Setup and configuration
aibox setup                   # setup wizard: check and complete installation; safe to rerun
aibox setup --check           # report the state of each step without changing anything

# Persistent container (default; fixed name aibox-dev, not tied to one project)
aibox [/path]                 # create/start and enter a shell in the directory (default: current); exit only closes this shell
aibox cc [/path]              # enter and start Claude Code; "claude" is also accepted
aibox codex [/path]           # enter and start Codex CLI
aibox start                   # create/start and refresh the proxy without a shell
aibox restart                 # restart and refresh the proxy service
aibox exec <cmd> [args]       # run a command as the ordinary machine user
aibox update [cc|codex]       # check for newer CLIs inside the machine; update after confirmation
aibox version [cc|codex]      # show versions actually installed in the machine
aibox set memory=8G cpus=4    # change an existing machine's resources; takes effect after restart
aibox stop                    # keep the persistent system disk
aibox logs [-f]
aibox delete                  # confirm, then delete the persistent container and its system disk; alias: rm
aibox migrate                 # migrate old login state and settings into ~/.aibox (also checked on first launch)
aibox build [--no-cache]      # build the base image, then the persistent-container image

# Temporary containers (removed on exit; only the selected project is mounted)
aibox tmp [/path/to/project]
aibox tmp cc [/path/to/project]     # "claude" is also accepted
aibox tmp codex [/path/to/project]
aibox tmp list [-a]                 # running temporary containers; -a includes stopped ones; alias: ls
aibox tmp enter [number|project|container]
aibox tmp logs <number|project|container> [-f]
aibox tmp stop <number|project|container>
aibox tmp stop --all                # confirm, then stop all temporary containers
aibox tmp clear                     # confirm, then remove stopped containers; alias: prune
aibox tmp build [--no-cache]        # build only the base image
aibox tmp update [cc|codex]         # check versions, then incrementally update the base image
aibox tmp version                   # show the temporary-container image's target CLI versions

# General
aibox status
aibox help                    # also -h / --help
aibox --version               # aibox's own version (also -V)

# Clipboard image bridge (host-side watcher; applies to both container types)
aibox clip install
aibox clip status
aibox clip restart
aibox clip doctor
aibox clip uninstall
```

`aibox tmp enter`, `stop`, and `logs` resolve their target the same way: a number from the current
`aibox tmp list`, a project name, or a full container name. `aibox tmp enter` opens another shell in
an existing container; exiting that extra shell does not stop the original container.

`aibox status` shows, on one screen: the service, the base image, the persistent-container image,
the target CLI versions, the login-state directory `~/.aibox`, the clipboard
bridge, then a persistent-container block (state, image, CPUs, memory, system disk, IP address, home
mount, machine user, and timestamps), and finally the running temporary containers. It exits
non-zero when the service is up but the persistent container cannot be queried.

Every temporary launch creates a separate `aibox-<project>-<time>-<launcher-pid>` container
carrying a `com.simpletang.ai-sandbox.managed=true` label. Management commands only recognize
`aibox-*`, so unrelated `ai-*` containers are never included in bulk stop or cleanup. Use the
native `container` commands to handle legacy `ai-*` containers left by an older release.

The persistent container lives in the separate `container machine` namespace and always uses the
name `aibox-dev`. `aibox tmp list`, `stop`, and `clear` never manage it. `aibox`, `aibox cc`, and
`aibox codex` create it from `ai-sandbox-dev:latest` when it does not exist and boot it when it is
stopped. `aibox start` boots it and refreshes the machine's system timezone and local proxy without
opening a shell, while `restart` reboots it and performs the same refresh. Locale and custom
variables are session settings applied by `aibox`, `aibox cc` / `codex`, and `aibox exec`;
timezone also updates `/etc/localtime` and `/etc/timezone`. `aibox exec` allocates an interactive
TTY. Only `aibox delete` removes the persistent system disk.

Where the old commands went: `aibox dev ...` has been removed, and the old persistent development
machine is now the default persistent container (`aibox dev` becomes `aibox`, `aibox dev start`
becomes `aibox start`, and so on). The old top-level ephemeral-container commands moved under
`aibox tmp`; running `aibox list`, `ls`, `enter`, `clear`, or `prune` without `tmp` prints an error
pointing to `aibox tmp ...`. The old `aibox start` that only started the container service now
starts the persistent container (and the service, if needed).

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

`aibox status` includes a clipboard-bridge line that distinguishes not installed, running with an
image ready, running with an empty clipboard, and a stale heartbeat meaning the watcher died — so a
broken bridge shows up in the ordinary status check.

Inside the sandbox press **Ctrl+V**, not ⌘V — the macOS terminal intercepts ⌘V as a text paste, so
it never reaches the container.

The bridge path differs per container type and `ai-box` injects `CLIP_BRIDGE_DIR` accordingly. The
persistent container already mounts the whole host home with `--home-mount rw`, so the path matches
macOS exactly; a temporary container mounts only the project directory, so `~/.clipboard-bridge` is
additionally mounted read-only at `/run/aibox/clipboard-bridge` (or reused from the project mount
when the project directory already contains it). When the host side is not installed nothing is
mounted and the shim quietly reports no image.

`aibox clip install` copies the watcher script to `~/.aibox/clipboard/` and points the launchd
agent at that copy, so replacing or moving the program directory does not break it. After updating
aibox, run `aibox clip restart` to switch the running watcher to the new script.
`aibox clip uninstall` also removes the copy.

The watcher mirrors **images only, never clipboard text**, so passwords copied from a password
manager are never written to disk. See [`clipboard-bridge/README.md`](clipboard-bridge/README.md)
for the mechanism, architecture diagram, and troubleshooting.

## Development Toolchains

The image includes Claude Code, Codex, and the basics they need (Node.js, Python, git, and common
shell tools). It does not include JDK, Maven, Gradle, or other language toolchains. When you need
one:

- Persistent container: its system disk is kept, so install it inside the machine, for example
  `sudo apt-get install openjdk-17-jdk maven`, and it stays available. `aibox delete` removes the
  installed software together with the machine.
- Temporary containers are deleted on exit, so anything installed there is lost; use the
  persistent container for projects that need a fixed toolchain.

In proxy mode the temporary container's firewall allows only connections through the local proxy.
Programs that honor `HTTP_PROXY` and friends work as is; tools that do not, such as Java, Maven,
and Gradle, need the proxy (`127.0.0.1:8080`) configured explicitly, for example:

```bash
java -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=8080 \
     -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=8080 -jar app.jar
```

## Updates and Rebuilds

### Upgrading aibox itself

```bash
brew upgrade aibox                 # Homebrew install
git -C /path/to/ai-sandbox pull    # git clone
aibox clip restart                 # if clipboard image pasting is enabled
```

User data in `~/.aibox` is left untouched by upgrades. See [CHANGELOG.md](CHANGELOG.md) for each
release's changes and upgrade notes.

To switch from a git clone to Homebrew, run `brew install simpletang/tap/aibox` and then
`aibox setup` once; it handles the old `~/.local/bin/aibox` symlink and the completion line. Delete
the old clone once everything works.

### Claude Code and Codex

The persistent container has its own writable system disk and does not change when its image is
rebuilt, so its CLIs are upgraded in place. `aibox update`, optionally limited to `cc` or `codex`,
first reads the versions installed in the machine, queries the npm mirror (npmmirror) for the latest
ones, prints `current -> latest` for each, and asks `[y/N]` before installing anything. If nothing
is newer, it simply exits. The install uses the machine's local gost service when a proxy is
configured and does not change the temporary-container image's version pins. `aibox version
[cc|codex]` shows the versions actually installed in the machine.

Temporary containers use the base image, so `aibox tmp update [cc|codex]` updates the image. It
checks the npm mirror, shows the pinned and latest versions, asks for confirmation, and records the
new versions in `~/.aibox/versions.env`; it does not modify any file in the program directory. It
then performs an **incremental update** via `Dockerfile.update`: a single `npm install` layer
stacked on top of the existing image, downloading only the packages that actually changed. This
skips the apt/locale/pip layers entirely and does not depend on the builder's layer cache (which is
lost whenever the builder container is deleted and recreated, turning a full rebuild into a
re-download of every dependency). If the local image is missing or the incremental build fails, the
command offers a full rebuild instead. Running containers keep their old image; new temporary
containers use the updated one.

Each incremental update adds a new layer while older CLI files remain in lower layers, so the image
grows slowly over repeated updates. Run `aibox tmp build` occasionally to squash it. Full builds
pass the effective versions as `--build-arg`: the newer of the Dockerfile default and the
`versions.env` entry. A full rebuild therefore reproduces the same versions, and a newer Dockerfile
default shipped with a later aibox release takes over automatically.

Rebuild and sync rules:

- Run `aibox build` (base image, then persistent-container image) after changing `Dockerfile`,
  `network-lockdown.sh`, `LOCALE_GEN`, a pinned CLI version, or `~/.aibox/third_party/gost`.
  If you only use temporary containers, `aibox tmp build` is enough.
- `aibox build` does not replace an existing persistent container; it keeps its own system disk.
  To move it to a new image as a whole (for example after changing `Dockerfile.dev`), back up any
  system-disk data you need, run `aibox delete`, and run `aibox` to recreate it. Deleting it does
  not delete files in the mounted host home.
- Every persistent-container start first copies the helper scripts (`dev-profile.sh`,
  `dev-shell.sh`, `dev-configure.sh`, `dev-proxy-run.sh`, `dev-tools.sh`, `dev-cache-trim.sh`,
  `aibox-dev-proxy.service`, `aibox-dev-cache-trim.service`) from the program directory into `~/.aibox/machine/`, then, as root,
  installs them from there, together with `~/.aibox/third_party/gost`, into the existing machine.
  Updating aibox or editing these files therefore takes effect on the next start without
  recreating the machine, wherever the program directory is.
- Changes to `~/.aibox/aibox.conf` and the symlinked `ai-box` launcher apply on the next invocation.
  Ordinary `entrypoint.sh` edits are mounted into temporary containers as a launch-time snapshot,
  but changes involving image tools, users, or privileges still require a full rebuild.

After upgrading to the firewall-enabled design, run `aibox build` at least once. An older image does
not contain iptables, the dedicated gost user, or the root initialization entrypoint and cannot be
upgraded by the runtime entrypoint snapshot alone.

`aibox tmp version` and the version line in `aibox status` show the temporary-container image's
build target: the newer of the Dockerfile default and the `~/.aibox/versions.env` entry.
`aibox tmp version` marks versions that come from `versions.env`. They do not inspect an
already-built image, so they can differ from that image until a successful rebuild.

## Troubleshooting

| Symptom | Check or action |
| --- | --- |
| Unsure which installation step is missing | Run `aibox setup --check` (or `./setup.sh --check` in the clone before `aibox` is installed), then `aibox setup` to complete the missing steps. |
| `container` is unavailable | Confirm macOS 26, Apple silicon, and the Apple container installation. This project does not use Docker. |
| The service is not running | Persistent-container commands start it automatically; `aibox tmp` and `aibox build` do not. Run `container system start` (or `aibox start`, which also creates/boots the persistent container), then check `aibox status`. |
| `aibox` reports a missing persistent-container image | Run `aibox build`; it builds the base image and then the persistent-container image. |
| `aibox tmp` reports a missing image | Run `aibox build` (or `aibox tmp build` for the base image only). |
| `aibox` says the directory is outside the host home | The persistent container only mounts the host home; use `aibox tmp /path` for directories outside it. |
| `aibox` says it is a macOS host launcher, or not to run it with sudo or as root | Run it from a Mac terminal as your ordinary user; do not run `aibox` inside the persistent container or with `sudo`. |
| Every run says the `aibox.conf` in the program directory is no longer read | Both locations have a configuration with different contents. `~/.aibox/aibox.conf` is the effective one; merge any settings you need into it and delete the old file. |
| A launch after upgrading asks how to migrate old data | Expected, once: choose the persistent container's state, the temporary container's, or a merge. To decide later, postpone and run `aibox migrate` afterwards. |
| Some settings or sessions are missing after migrating | Sessions still running during the migration kept writing to the old location. Recover from the backups in the machine's `~/.claude.pre-aibox-<time>/` or `~/.aibox/legacy/`. |
| The first `aibox` after a Mac restart reports `Failed to connect to bus` | Update the host-side `ai-box`; it waits for the machine's systemd manager before applying system settings, without requiring deletion of the persistent container. |
| Build dependency downloads fail | The build still needs access to the base-image registry, Debian/PyPI, and npm sources. Fix that path or retry. |
| A configured proxy fails immediately | Confirm that `~/.aibox/third_party/gost` is Linux/arm64 and executable. Temporary containers need it present when the image is built (rebuild, then check `aibox tmp logs <target>`); the persistent container picks it up on the next start. |
| Lockdown components are missing or firewall initialization fails | Run a full `aibox build`. If it still fails, confirm Apple container accepted the launcher's `CAP_NET_ADMIN` capability. |
| A SOCKS proxy cannot resolve names | Try a `socks5h://` URL so the proxy resolves hostnames. |
| A locale falls back to `C.UTF-8` | Add it to `LOCALE_GEN` in the Dockerfile and rebuild. |
| A long CLI session becomes slow or is killed | Check host memory pressure; containers request `8192M` by default. Raise `AIBOX_MEMORY` in `aibox.conf` for temporary containers, or run `aibox set memory=...` followed by `aibox restart` for the persistent container. Compact or restart long Claude sessions when appropriate. |
| `aibox` says `AIBOX_MEMORY` or `AIBOX_CPUS` is malformed | Write memory with a unit (`8G`, `4096M`) and the CPU count as a positive integer, or rerun `aibox setup` to regenerate the file. |
| `java` / `mvn` disappeared after upgrading | The image no longer includes a JDK or Maven; see [Development Toolchains](#development-toolchains). In an existing persistent container the `/opt/java` and `/opt/maven` from the old image are still there but no longer added to `PATH`. |
| The Mac stalls, kills many processes or reboots after several containers worked on large mounts | The host keeps one open file handle for every file and directory a container has cached, and the whole Mac shares a limit of about 490,000; once it is full, system processes crash. A grep / find over a large mount caches 10,000–20,000 files per second. In the persistent container, the `aibox-dev-cache-trim` service checks every 2 seconds and releases the cache once it passes 50,000 files (released files are a little slower on their next access); `sudo journalctl -u aibox-dev-cache-trim` lists each release. Temporary containers cannot release it, so handles return only when the container stops: with the whole home as the working directory, Claude Code pinned 100,000+ handles per container at startup, which is why the launcher now uses an empty working directory there. In temporary containers, mount specific projects, do not walk the whole home, `exit` when done, and check `aibox tmp list` for leftovers. |
| A temporary container keeps running after the terminal closed or SSH dropped | When you log in first and then run `aibox tmp`, the launcher stops its container. If you run it directly with `ssh host "aibox tmp ..."` and the connection drops, macOS does not notify the launcher and the container stays in the background: find it with `aibox tmp list` and stop it with `aibox tmp stop`. |
| Two projects share Claude state | Give their mounted directories different basenames. |
| Apple container's builder is stuck | Follow Apple container diagnostics; recreating the builder may discard builder state and should be a deliberate last resort. |
| The mounted project directory is empty inside a temporary container | Apple container's single-file mounts also share the file's parent directory; when that parent is itself the source of another mount (e.g. `entrypoint.sh` while mounting the sandbox repo as the project), that mount silently comes up empty. `ai-box` avoids this by mounting a launch-time snapshot of `entrypoint.sh`; if it still happens, update the host-side `ai-box` or restart the container service. |

The temporary container's startup banner reports the effective project, mount, proxy source,
timezone, locale, and IPv6 status. It is the first place to check after changing configuration.

## Development, Contributions, and Security Reports

Keep changes focused and preserve compatibility with macOS Bash 3.2. Run the portable smoke suite:

```bash
./tests/smoke.sh
```

CI runs the smoke checks on macOS and Ubuntu. A real image build and interactive runtime test still
require a compatible Apple silicon Mac with Apple container. For shell changes, `bash -n` and
ShellCheck are also useful:

```bash
bash -n ai-box setup.sh entrypoint.sh ai-box-completion.sh
shellcheck ai-box setup.sh entrypoint.sh ai-box-completion.sh
```

Issues and pull requests are welcome. Never attach `aibox.conf`, API keys, proxy URLs containing
credentials, the contents of `~/.aibox`, or unredacted logs. For a vulnerability, use GitHub's
private **Security -> Report a vulnerability** flow. If private reporting is unavailable, contact
the maintainer privately through the contact method on their GitHub profile rather than opening a
public issue.

## Uninstall

With Homebrew, replace removing the symlink and the clone below with `brew uninstall aibox` (and
`brew untap simpletang/tap` if you no longer need the tap).

1. Stop running temporary containers with `aibox tmp stop --all`, remove stopped ones with
   `aibox tmp clear`, then delete the persistent container and its system disk with `aibox delete`
   if it exists.
2. If you enabled clipboard image pasting, run `aibox clip uninstall`. Remove the `aibox` symlink
   from `$HOME/.local/bin` and remove the completion line from your shell startup file.
3. Delete the `ai-sandbox:latest` and `ai-sandbox-dev:latest` images with Apple container's
   image-management command if they are no longer needed.
4. Delete the clone. Configuration, login state, and `third_party/` assets live in `~/.aibox`,
   outside the clone, and are not removed with it.
5. For a full removal, back up what you need from `~/.aibox` (for example `aibox.conf` and login
   state), then delete it with `rm -rf ~/.aibox`. It contains authentication secrets, so delete it
   deliberately.

## License and Upstream Software

The original scripts and documentation in this repository are licensed under the [MIT License](LICENSE).
That license does not relicense Apple container, the base Node/Debian image, Claude Code, Codex CLI,
`ai-ipcheck`, `gost`, or their dependencies. Their own licenses and
terms continue to apply:

- [Apple container](https://github.com/apple/container)
- [Node official container image](https://hub.docker.com/_/node) and [Debian copyright information](https://www.debian.org/legal/licenses/)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code/overview)
- [OpenAI Codex CLI](https://github.com/openai/codex)
- [`ai-ipcheck`](https://github.com/stormzhang/ipcheck)
- [`gost`](https://github.com/go-gost/gost)

Review the version pins in the Dockerfile and the license or notice files included with every binary
you choose to add to `~/.aibox/third_party/`.
