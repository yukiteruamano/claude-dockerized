# Claude Dockerized - Secure Sandbox Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Run [Claude Code](https://code.claude.com/docs) (native binary, pinned version) in a secure, isolated Docker container with controlled access to your projects. This setup provides Claude Code with just enough access to be useful while maintaining strong security boundaries.

## Table of Contents

- [Security Features](#-security-features)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Usage](#-usage)
- [Configuration](#-configuration)
- [Portability & Sharing](#-portability--sharing)
- [Advanced Usage](#-advanced-usage)
- [Updates, trust and rollback](#-updates-trust-and-rollback)
- [Hardening profiles and session integrity](#️-hardening-profiles-and-session-integrity)
- [Performance Optimizations](#-performance-optimizations)
- [Testcontainers Support](#-testcontainers-support)
- [Troubleshooting](#-troubleshooting)
- [File Reference](#-file-reference)

## 🔒 Security Features

- **Isolated Environment** - Claude Code only has access to the mounted project directory
- **Persistent Configuration** - All Claude Code state lives self-contained under `~/.config/claude-dockerized/home/`, so MCP servers, sessions, auth, plugins and LSP servers survive container restarts and image rebuilds. Managed files (`settings.json`, hooks) are mounted **read-only**: edit them on the host
- **Native Security Layer** - A generated `~/.config/claude-dockerized/` directory (managed `settings.json` with `permissions.deny/ask`, `sandbox`, `disableBypassPermissionsMode`, `DISABLE_AUTOUPDATER=1`, plus native `PreToolUse` hooks and the vendored policy pattern sets) is never mounted as a whole: managed files reach the container through fine-grained read-only mounts, so every session receives them and cannot relax them
- **Configurable policy** - `setting.security_policy` selects `strict`, `balanced` (default, drops the noisy cloud/multi-tenant false positives) or `none`
- **Remote flows allowed** - Git over SSH, remote MCP servers (`http`/`sse`), registries and APIs work in every policy mode; only destruction, exfiltration, secrets and Docker escapes are blocked
- **No auto-updates** - The pinned Claude Code version (`2.1.284`) always runs; upgrades happen only through `claude-dockerized update` (image rebuild)
- **No host Docker control by default** - The host Docker socket is **not** mounted unless you opt in with `setting.docker_socket=true` (it is root-equivalent on the host; see [SECURITY.md](SECURITY.md))
- **Session Persistence** - Login, sessions, plugins, MCP state and LSP servers persist across container restarts and rebuilds
- **Non-root User** - Runs as the host user via `--user <uid>:<gid>`; no root process ever starts in the container (plus `--cap-drop=ALL` and `no-new-privileges`)
- **Limited Blast Radius** - Commands like `rm -rf .` only affect the project directory, not your entire system

## 📋 Prerequisites

1. **Docker** installed and running
2. **Optional configuration files** (if you have them):
   - `~/.gitconfig` - Git configuration (mount it explicitly, see below)

**No local Claude Code installation required!** Authentication and all Claude Code operations run through Docker.

## 🚀 Quick Start

### First-Time Setup

```bash
# 1. Install. Recommended: download, inspect, then run
curl -fsSLO https://raw.githubusercontent.com/yukiteruamano/claude-dockerized/master/install.sh
less install.sh && bash install.sh
#    (one-liner: curl -fsSL .../install.sh | bash; from a clone: ./install.sh)
#    Non-interactive: ./install.sh --yes · only some steps: ./install.sh --only completions,aliases
#    Pin a release: CCODE_REF=v1.2.0 bash install.sh

# 2. Pin the release-signing key (enables verified updates; compare the fingerprint)
claude-dockerized update --trust-key maintainer.asc

# 3. Build the Docker image
claude-dockerized build

# 4. Authenticate (no local Claude Code needed!)
claude-dockerized auth

# 5. Run Claude Code in your project (from any directory!)
claude-dockerized run
# or
claude-dockerized run /path/to/your/project
```

### Authentication

**No local Claude Code installation required!** You can authenticate directly through Docker:

```bash
# Authenticate (browser or pasted OAuth code)
claude-dockerized auth

# This will:
# - Run 'claude auth login' inside the container
# - Save credentials to ~/.config/claude-dockerized/home/.claude/.credentials.json on your host
# - Make authentication available to all future Claude Code runs
```

Your authentication is stored on the host machine (mode `0600`) and persists across container restarts and image rebuilds.

### Daily Usage

```bash
# Run in current directory (works from anywhere after setup)
claude-dockerized run

# Run in specific project
claude-dockerized run ~/projects/my-app

# Non-interactive prompt
claude-dockerized exec "Explain this repo"

# Check version
claude-dockerized version

# Verified self-update: signed release, preview, confirm, sync, rebuild
claude-dockerized update
claude-dockerized rollback        # undo the last update if needed
```

### Global Installation

No symlink, stub or copy is ever created in `~/.local/bin`. The binary lives
in `bin/` of the self-contained checkout (`~/.local/share/claude-dockerized`
by default) and is reached via `PATH`:

```bash
export PATH="$HOME/.local/share/claude-dockerized/bin:$PATH"
```

`install.sh` (via `claude-dockerized install`) adds that line to `~/.bashrc`/`~/.zshrc` for you
(idempotent, never duplicated).

### Shell Aliases (Automatic)

`install.sh` installs these aliases automatically (in both `~/.bashrc` and `~/.zshrc` when those files exist, repaired on re-runs). They point at the command on `PATH`:

```bash
alias ccd='claude-dockerized'
alias ccd-run='claude-dockerized run'
alias ccd-auth='claude-dockerized auth'

# Then use them anywhere (after `source ~/.bashrc` or a new shell)
cd ~/my-project
ccd run
```

### Shell Completion (Automatic)

`claude-dockerized install` wires the completions into your shell rc. To do it by hand:

```bash
# Bash (add to ~/.bashrc)
source /path/to/claude-dockerized/completions/bash.sh

# Zsh (add to ~/.zshrc, after compinit)
source /path/to/claude-dockerized/completions/zsh.sh
```

Every command, its subcommands and flags complete (including `update --channel`, `--trust-key` files, `install --only` steps and `config sync --check`); a CI test keeps the completions in sync with the commands.

## 📖 Usage

### Available Commands

```bash
claude-dockerized build          # Build Docker image
claude-dockerized auth           # Authenticate (claude auth login)
claude-dockerized run [DIR]      # Run Claude Code (default: current dir)
claude-dockerized models         # Show the effective default model
claude-dockerized exec "..."     # Non-interactive prompt (claude -p)
claude-dockerized mcp list       # MCP servers and their status
claude-dockerized mcp login NAME # OAuth login for an MCP server
claude-dockerized plugin list    # Loaded plugins
claude-dockerized stats          # Local session-storage statistics
claude-dockerized debug paths    # Resolved generated-home paths
claude-dockerized debug doctor   # Native claude doctor inside the container
claude-dockerized doctor [--json] # Host + container checks, summary, exit 1 on failure
claude-dockerized install        # Install / repair PATH, config, completions, aliases
claude-dockerized update --check # 0 up to date, 100 update available, 1 error
claude-dockerized update         # Verified self-update (signed tag, preview, confirm, sync, rebuild)
claude-dockerized rollback       # Undo the last update (checkout + previous image)
claude-dockerized build [--pull] # Build the image (--no-cache, --pull)
claude-dockerized version [--json] # Wrapper, guard, policy and Claude Code versions (no Docker needed)
claude-dockerized config show    # Show parsed configuration
claude-dockerized config edit    # Edit wrapper config in $EDITOR
claude-dockerized config path    # Print wrapper config file path
claude-dockerized config sync [--check]  # Refresh security layer (hooks/policies/settings) from repo
claude-dockerized config claude path     # Print managed settings.json path
claude-dockerized config credentials path # Print credentials file path (values never printed)
claude-dockerized clean          # Remove the Docker image
claude-dockerized help [COMMAND] # Overview, or one command's details (also: COMMAND --help)
```

`run` passes everything after `--` to Claude Code: `claude-dockerized run . -- --resume`.
Its exit status is Claude Code's own.

### Dry Run Mode

Preview the `docker run` command without executing it:

```bash
DRY_RUN=true claude-dockerized run /path/to/project
```

This prints the full Docker command with all volume mounts, environment variables, and flags — one flag per line — useful for debugging configuration issues. Secrets travel via `--env-file` (only the file path is shown).

Output is plain when it is not a terminal; `--no-color`, `NO_COLOR=1` or `TERM=dumb` force plain output and `CLICOLOR_FORCE=1` forces color. Warnings and errors go to stderr.

### Alternative Runners

```bash
./run-simple.sh /path/to/your/project
```

### Inside the Container

Once Claude Code starts, use it as usual (`/model` to switch models, `/mcp` for MCP servers, `/hooks` to inspect hooks, `/status` to confirm settings loaded, `/sandbox` for sandbox state).

## 🔧 Configuration

### Configuration File

The wrapper is configured through `~/.config/claude-dockerized/config`
(INI-style, created by `./install.sh`).

There is **no `.env` file**: secrets live in `setting.env_file` (a dotenv file
under `~/.config/claude-dockerized/`, loaded with `docker --env-file`), and
`TERM` is forwarded automatically. The
container runs as your host UID/GID (`--user`), so no `HOST_UID`/`HOST_GID`
mapping is needed.

### Volume Mounts

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `$PROJECT_DIR` | `$PROJECT_DIR` (with `$HOME` stripped) | read-write | Your project files |
| `~/.config/claude-dockerized/home/.claude/settings.json` | `/home/coder/.claude/settings.json` | **read-only** | Managed settings (permissions, hooks, sandbox, no-autoupdate) |
| `~/.config/claude-dockerized/home/.claude/hooks-guard/` | `/home/coder/.claude/hooks-guard/` | **read-only** | Native `PreToolUse` hooks + policy data |
| `~/.config/claude-dockerized/home/.claude/CLAUDE.md` | `/home/coder/.claude/CLAUDE.md` | **read-only** | Managed session rules |
| `~/.config/claude-dockerized/home/.claude/.credentials.json` | `/home/coder/.claude/.credentials.json` | read-write (`0600`) | Login, persists across rebuilds |
| `~/.config/claude-dockerized/home/.claude/plugins/` + skills/agents/commands | same under `/home/coder/.claude/` | read-write | Your plugins and skills |
| `~/.config/claude-dockerized/home/.claude/.lsp.json` | `/home/coder/.claude/.lsp.json` | read-write | LSP config (when `setting.lsp=true`) |
| `~/.config/claude-dockerized/home/.claude.json` | `/home/coder/.claude.json` | read-write | MCP user-scope state |
| `~/.config/claude-dockerized/home/.local/bin/` | `/home/coder/.local/bin/` | read-write | LSP/formatter binaries |
| `~/.config/claude-dockerized/home/.local/share|state/claude/` + `.cache/claude/` | same | read-write | Sessions, history, caches |
| `~/.mcp-auth/` | `/home/coder/.mcp-auth/` | **read-write** | MCP OAuth store for `mcp-remote` servers (optional) |
| `~/.composio/` | `/home/coder/.composio/` | read-write | Composio CLI binary + login (when present) |
| `~/.config/claude-dockerized/home/.gnupg/` | `/home/coder/.gnupg/` | read-write | Mirrored **public** GnuPG material + agent socket (only with `setting.gpg_agent_support=true`); `private-keys-v1.d/` is never copied |

The wrapper's own directory (`~/.config/claude-dockerized/`) is **not** mounted at all, and `~/.claude` is never mounted as a whole: managed files travel through fine-grained read-only mounts.

### Persistent Configuration & Security Layer

The wrapper is **self-contained and replaces native host usage**: all of Claude Code's
state lives under a single host directory (`~/.config/claude-dockerized/home/`,
override with `CCODE_HOME`), mirroring the container home layout. Back up or move
that one directory and the whole setup travels with it. The host XDG dirs
(`~/.claude`, `~/.local/...`) are never touched.

```text
~/.config/claude-dockerized/
│   config                          ← wrapper INI config (mounts, settings)
│   env                             ← secrets dotenv (600, never mounted)
│   CLAUDE.md                       ← session rules source
│   hooks/claude-guard-*.sh         ← hook sources (versioned in the repo)
│   hooks/guard-eval.js             ← policy evaluator source
│   hooks/policies/*.json           ← policy pattern sets + local allowlist
│
└── home/                            ← mirrors /home/coder, mounted piece by piece
    ├── .claude/
    │   │   settings.json            ← GENERATED (managed, ro mount) — do not edit
    │   │   .credentials.json        ← login, 0600, rw
    │   │   hooks-guard/             ← mirrored hooks + policies, ro mount
    │   │   CLAUDE.md                ← mirrored rules, ro mount
    │   │   plugins/ skills/ agents/ commands/ ← yours, rw
    │   │   .lsp.json                ← generated when setting.lsp=true, rw
    ├── .claude.json                 ← MCP state, rw
    ├── .local/bin/                  ← LSP/formatter binaries, rw
    └── .local/share|state/claude/ + .cache/claude/ ← sessions/history/caches, rw
```

Because everything lives on the host, all state persists across `docker` up/down
cycles **and** image rebuilds:

- **Editing config:** managed files are mounted **read-only**, so edit on the host (`claude-dockerized config edit` for wrapper settings). `claude mcp add/remove` and `claude plugin install/update/remove` are intentionally disabled inside the container; `claude mcp login/logout` keep working (tokens live in read-write mounts).
- **Security layer:** generated on the host and mirrored on every run (wrapper-managed). The hooks are versioned in the repo (`hooks/claude-guard-*.sh`); bumping `CLAUDE_DOCKERIZED_GUARD_VERSION` refreshes installs (the previous copy is backed up to `.bak`).
- **Policy mode:** `setting.security_policy` (default `balanced`) selects which patterns the hooks enforce. `balanced` drops cloud/multi-tenant rules and common false positives while keeping the dangerous ones; `strict` enforces everything; `none` disables the vendored patterns but keeps the built-in backstops. Local exceptions live in `hooks/policies/allow-patterns.json`.
- **No auto-updates:** `env.DISABLE_AUTOUPDATER=1` is always set in the managed settings (verify with `claude-dockerized doctor`, which also runs the native `claude doctor`). Upgrades happen only via `claude-dockerized update`, which rebuilds the image with the pinned `CLAUDE_CODE_VERSION` (default `2.1.284`; override per-build with `update --claude-version X.Y.Z`).

### Custom Global Configuration (Optional)

**Advanced Users:** You can configure custom volume mounts and settings for all projects:

- **SSH agent forwarding**: Enable `setting.ssh_agent_support=true` for secure git over SSH (recommended). Forwards only the host `SSH_AUTH_SOCK` and mounts `~/.ssh/config` + `known_hosts` read-only; private keys are never mounted.
- **GnuPG agent forwarding**: Enable `setting.gpg_agent_support=true` to sign commits (`git commit -S`) with the keys held by your host gpg-agent (private keys never enter the container). Run `claude-dockerized doctor` to verify.
- **Global git configuration**: Mount `~/.gitconfig`
- **Default model**: Set `setting.model=sonnet` (passed as `--model`; `/model` still works per session)
- **LSP servers**: Set `setting.lsp=true` and `setting.lsp_servers=go,ts,python,rust` to install language servers into the generated home and generate `.lsp.json`
- **Formatters**: Set `setting.formatters=true` to install formatters and enable the formatter plugins

#### Config Format

```ini
# Settings (see examples/config.example for the full list)
setting.ssh_agent_support=true
setting.gpg_agent_support=true
setting.gpg_allow_main_socket=false
setting.gpg_autostart_agent=true
setting.memory=4g
setting.cpus=2
setting.env_file=~/.config/claude-dockerized/env
setting.model=sonnet
setting.cleanup_days=7
setting.lsp=false
setting.lsp_servers=ts,python
setting.formatters=false

# Custom volume mounts (read-only by default)
# Format: mount.<name>=<host_path>:<container_path>[:rw]
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig

# Secrets go in setting.env_file (dotenv KEY=VALUE, mode 600), e.g.:
#   ANTHROPIC_API_KEY=...
#   CLAUDE_CODE_OAUTH_TOKEN=...
```

#### Examples

**Example 1: Git configuration with SSH agent forwarding (Recommended)**
```ini
setting.ssh_agent_support=true
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
```

Your private keys never enter the container: only `SSH_AUTH_SOCK` and the non-secret `~/.ssh/config`/`known_hosts` are shared (read-only). Do not mount `~/.ssh` — it is refused.

**Example 2: Commit signing with the host GnuPG agent**
```ini
setting.gpg_agent_support=true
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
```
Inside the container, configure git to use your signing key (e.g. `git config --global user.signingkey <KEYID>` and `commit.gpgsign true`). Only the public keyring and the host `gpg-agent` socket are shared; private keys stay on the host. It prefers the restricted `S.gpg-agent.extra` socket. Verify with `claude-dockerized doctor`.

**Important:** many Docker setups cannot bind a socket under a per-user tmpfs (`/run/user/<uid>/gnupg/…`) — they create an empty directory instead. The wrapper transparently relays the agent socket through a socket on a normal filesystem (under `~/.config/claude-dockerized/gnupg-relay/`) using `socat`, and mounts that. Install `socat` on the host.

Pinentry runs on the **host** agent, so it is independent of the container's desktop.

**Example 3: API keys and credentials (secrets file recommended)**
```ini
setting.env_file=~/.config/claude-dockerized/env
```

Create the file with `install -m 600 /dev/null ~/.config/claude-dockerized/env`, then add one `KEY=VALUE` per line. It must live under `~/.config/claude-dockerized/` (anywhere else is refused) and is passed with `docker --env-file`, so values never appear on the command line; the file itself is never mounted.

**Example 4: LSP servers**
```ini
setting.lsp=true
setting.lsp_servers=ts,python
```
Binaries install into `~/.config/claude-dockerized/home/.local/bin/` (on `PATH` in the container) and `.lsp.json` is generated. Everything persists across rebuilds. Check with `claude-dockerized doctor`.

**Note:**
- **SSH Agent Support**: Use `setting.ssh_agent_support=true` instead of mounting `~/.ssh` (refused)
- **GnuPG Agent Support**: Use `setting.gpg_agent_support=true` instead of mounting `~/.gnupg` (refused)
- Mounts are **read-only by default** (append `:rw` for read-write)
- Paths use `~` which is expanded to your home directory at runtime
- Re-run `./install.sh` anytime to update your custom configuration

## 🌍 Portability & Sharing

**This setup is fully portable!** It uses `$HOME` instead of hardcoded paths and works across different users and systems.

```bash
git init
git add .
git commit -m "Initial Claude Docker setup"
git remote add origin <your-repo-url>
git push -u origin master
```

Users can then:
```bash
curl -fsSL https://raw.githubusercontent.com/yukiteruamano/claude-dockerized/master/install.sh | bash
claude-dockerized build
claude-dockerized run
```

### Platform Compatibility

- **Linux**: Works out of the box
- **macOS**: Works with Docker Desktop
- **Windows (WSL2)**: Works in WSL2 terminal
- **Windows (Native)**: Use WSL2 instead

### What to Share

✅ Safe to share:
- Dockerfile
- Shell scripts and hooks
- Documentation
- .gitignore

❌ Never share:
- Secrets file (`env`) or `.credentials.json`
- Personal `~/.config/claude-dockerized/home/` state
- Personal `.mcp-auth/`

## 🔍 Advanced Usage

### Python Development with uv

The container includes [uv](https://docs.astral.sh/uv/), a fast Python package manager:

```bash
uv init my-project              # Create a new Python project
uv add requests                 # Add dependencies
uv run python script.py         # Run scripts in isolated environment
```

### Adding Additional Tools

Edit `Dockerfile`:

```dockerfile
RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
```

Then rebuild: `claude-dockerized build`.

### Pinned Claude Code version

```dockerfile
# Default (repo-pinned)
ARG CLAUDE_CODE_VERSION=2.1.284
```

```bash
# Rebuild with a different version; the pin is kept for later `build`s and
# the binary's sha256 is recorded on its first build (a later build of the
# same version must produce the same bytes)
claude-dockerized update --claude-version 2.1.300
```

## 🔄 Updates, trust and rollback

`claude-dockerized update` only applies code it can verify:

1. fetches once from the pinned `origin` (a changed remote is refused);
2. picks the newest `vX.Y.Z` tag that fast-forwards your checkout
   (`--channel branch` follows signed upstream commits instead);
3. verifies its signature against the keys **you** pinned in
   `~/.config/claude-dockerized/trust` (`update --trust-key FILE`, confirmed
   interactively against the fingerprint) — never keys shipped with the update;
4. shows the commits and diffstat, flagging files that run on your host, in
   the image or as the guard; asks before applying (`--yes` to skip,
   `--dry-run` to stop here);
5. fast-forwards, then the **new** code re-syncs the security layer and
   rebuilds the image, keeping the previous one as `claude-dockerized:prev`.

`claude-dockerized rollback` restores the previous checkout and image.
Unsigned releases are refused; `--allow-unsigned` exists for emergencies and
needs a typed interactive confirmation. Maintainers: see
[.github/release-keys/README.md](.github/release-keys/README.md).

| Command | Exit status |
|---------|-------------|
| `update --check` | 0 up to date · 100 update available · 1 error |
| `update`, `rollback`, `build` | 0 success · 1 error |
| `doctor` | 0 all checks pass · 1 any check failed |
| `run`, `exec` | Claude Code's own exit status |

## 🛡️ Hardening profiles and session integrity

Defaults keep the runtime unchanged. Opt in with `setting.hardening`:

| Profile | Adds |
|---------|------|
| `off` (default) | — |
| `standard` | `--init`, `--pids-limit 4096`, private IPC |
| `strict` | standard + read-only root filesystem (tmpfs for `/tmp` and caches), read-only plugins / skills / agents / commands / `~/.local/bin` / `.composio` and project `.git` hooks/config, bridge network unless `setting.network` is set |

Image options: `setting.image_strip_setuid=true` (no setuid bits),
`setting.image_docker_cli=false` (no Docker CLI; only useful with the socket).

After every `run`, the wrapper compares fingerprints of the persistent paths a
session could plant code in (project git hooks/config and Claude settings,
`~/.local/bin`, plugins, skills, MCP servers, `.composio`) and lists every
change; the log is `~/.config/claude-dockerized/audit/sessions.jsonl` and
`doctor` shows the last entry. Disable with `setting.integrity_check=false`.

## 🐛 Troubleshooting

### Permission Denied on Scripts

```bash
chmod +x bin/claude-dockerized install.sh entrypoint.sh hooks/*.sh
```

### Config Files Not Found

```bash
# Run install script
./install.sh

# Or refresh the security layer
claude-dockerized config sync
```

### Permission Issues with Files

```bash
# The container runs as your host user; check it
echo "Host UID: $(id -u), GID: $(id -g)"

# Rebuild image
claude-dockerized build
```

### Container Won't Start

```bash
# Check Docker is running
docker info

# Remove and rebuild
docker rm -f claude-dockerized
claude-dockerized build
```

### Claude Code Not Updating

Claude Code never self-updates inside the container by design. To upgrade:

```bash
# Verified update (signed release) + sync + rebuild with the pinned version
claude-dockerized update

# Or rebuild with an explicit version
claude-dockerized update --claude-version 2.1.300
```

If `update` says the release is not signed by a trusted key, pin the
maintainer key first (`update --trust-key FILE`). If an update broke
something, `claude-dockerized rollback`.

### Login Lost / MCP needing re-auth

Your login lives in `~/.config/claude-dockerized/home/.claude/.credentials.json`. If it is missing, re-run `claude-dockerized auth`. Check `claude-dockerized doctor` first.

## 📁 File Reference

### Core Files

- **`Dockerfile`** - Container image definition (Debian trixie-slim + Node.js/NVM + uv + Claude Code native binary v2.1.284, no sudo, no npm)
- **`entrypoint.sh`** - Container entrypoint (resolves the workdir, sets up NVM/Node and execs the command; runs unprivileged, no UID/GID mapping)

### User Scripts

- **`bin/claude-dockerized`** - Main wrapper, no extension (run, exec, auth, mcp, plugin, build, update, rollback, doctor, version, config, clean, help, ...). Reached via `<install>/bin` on `PATH`; `bin/` holds only this binary
- **`install.sh`** - Curl-able bootstrap (runs the local `bin/claude-dockerized install`, or clones to `~/.local/share/claude-dockerized` first; full setup in one shot)
- **`run-simple.sh`** - Simplified runner script (delegates to `claude-dockerized run`)

### Shared Modules

- **`lib/config-lib.sh`** - Shared configuration library (mounts and their validation, env, managed policy and settings generation, sync, hardening profiles, LSP installs)
- **`lib/install-lib.sh`** - Install wizard library sourced by the wrapper's `install` command
- **`lib/update-lib.sh`** - Verified self-update (trust store, signature checks, origin pin, rollback)
- **`lib/integrity-lib.sh`** - Session integrity check and audit log
- **`lib/ui-lib.sh`**, **`lib/help-lib.sh`**, **`lib/diag-lib.sh`** - Output helpers, help texts, Docker preflight / doctor / version
- **`lib/doctor-container.sh`** - Diagnostics run inside the container by `doctor`

### Security Layer

- **`hooks/claude-guard-bash.sh`**, **`hooks/claude-guard-file.sh`** - Versioned native `PreToolUse` hooks (Bash/file confinement, policy modes, backstops)
- **`hooks/guard-eval.js`** - Vendored-pattern evaluator used by the bash hook
- **`policies/unsafe-tool-patterns.json`**, **`policies/prompt-injection-patterns.json`** - Vendored pattern sets
- **`policies/allow-patterns.json`** - Local allowlist (e.g. `.env.example`)
- **`policies/README.md`** - Provenance and refresh instructions

### Tests

- **`tests/run-all.sh`** - Runs every suite (`--integration` adds the Docker runtime checks, `--verbose` lists known gaps)
- **`tests/*.test.mjs`** - Guard: regression cases, bypass corpus (`tests/fixtures/guard-corpus.json`), fail-closed behavior, policy data, hook wiring, settings merge
- **`tests/*.test.sh`** - Wrapper: docker argv, mounts, config, hardening, integrity, self-update, supply chain, LSP installs, CLI/UI contract, threat-matrix traceability
- **`tests/integration/container.test.sh`** - Runtime contract inside the real image (skips without Docker)

### Shell Completion (`completions/`)

- **`completions/bash.sh`** - Bash shell completion script
- **`completions/zsh.sh`** - Zsh shell completion script

### Examples (`examples/`)

- **`examples/config.example`** - Example custom configuration file

### Documentation & Meta

- **`SECURITY.md`** - Security overview, known limitations, vulnerability reporting
- **`docs/security/`** - Threat model (T-01…T-30) and the Red (attacks), Blue (controls, detection, response) and Yellow (secure development) playbooks
- **`CONTRIBUTING.md`** - Contribution workflow and local checks (CI parity)
- **`.shellcheckrc`**, **`.hadolint.yaml`**, **`.editorconfig`** - Linter/formatter configuration

### Configuration

- **`.gitignore`** - Excludes sensitive files from Git
- **`.dockerignore`** - Excludes non-essential files from Docker build context

### How It Works

1. **Base Image**: Uses Debian Trixie slim for minimal footprint
2. **Docker CLI Only**: Installs only Docker CLI (uses host's Docker daemon via the opt-in socket)
3. **Development Tools**: Includes Node.js (via NVM), Python tooling (via uv), Git, jq, ripgrep and essential CLI tools
4. **Claude Code Installation**: Installs the pinned native binary (`v2.1.284`) via the official installer (`https://claude.ai/install.sh`)
5. **User Management**: Creates non-root `coder` user; the wrapper runs the container as your host UID/GID with `--user` and joins the image's `coder` group with `--group-add coder` (group-writable home), so no root process and no runtime remapping
6. **Entrypoint**: Resolves the project workdir, loads NVM/Node and execs Claude Code as the unprivileged user
7. **Volume Mounting**: Mounts only necessary files/dirs with appropriate permissions (managed files read-only, state read-write)

### The Blast Radius Concept

If Claude Code runs a dangerous command like `rm -rf .`:

- ❌ **Without Docker**: Could delete your entire home directory
- ✅ **With Docker**: Only affects the mounted project directory

This significantly reduces risk while maintaining full functionality.

## 📚 Additional Resources

- [Claude Code Documentation](https://code.claude.com/docs)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)

## ⚠️ Important Notes

1. **Docker Socket (opt-in)**: Not mounted by default. Set `setting.docker_socket=true` to use the host's Docker daemon — it is root-equivalent on the host, so enable it only when required.
2. **Network Access**: Container uses host network mode by default for convenience (`setting.network=bridge` for more isolation)
3. **Configuration Updates**: Managed files (`settings.json`, hooks) live in the generated home and are mounted **read-only**; modify wrapper settings on the host (`config edit`) and re-run. Auth/MCP-OAuth live in read-write mounts, so `auth`/`mcp login` keep working
4. **Persistent Data**: Project files plus the whole `~/.config/claude-dockerized/home/` state tree persist across restarts and rebuilds
5. **No sudo/apt inside**: The image ships no sudo — the agent runs as the host user, never as root, with all Linux capabilities dropped and `no-new-privileges` set, so it cannot escalate by design
6. **No self-updates**: Claude Code never updates itself inside the container (`DISABLE_AUTOUPDATER=1`); use `claude-dockerized update`
7. **Not a Replacement for Caution**: Review Claude Code's actions, especially with permissive settings

## 🚀 Performance Optimizations

This setup is optimized for minimal overhead:

- **Docker CLI Only**: Only installs Docker CLI (not the full daemon), saving ~200MB
- **Host Docker Daemon (opt-in)**: Uses your existing Docker daemon via socket mounting when `setting.docker_socket=true`
- **No Privileged Mode**: No need for `--privileged` flag or Docker-in-Docker
- **Shared Resources**: Shares Docker images/containers with host (no duplication)
- **Fast Startup**: No daemon initialization delay
- **Slim image**: LSP servers and formatters live in the generated home, not the image

## 🧪 Testcontainers Support

**Testcontainers support is available** (opt-in). Enable the host Docker socket first:

```ini
# ~/.config/claude-dockerized/config
setting.docker_socket=true
```

Then your integration tests can spin up Docker containers (they run on your **host's** Docker daemon, not inside the Claude container).

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### Third-Party Software

This project uses and packages the following third-party software:

- **[Claude Code](https://code.claude.com/docs)** - Proprietary (Anthropic; downloaded at image build time, pinned version)
- **Policy pattern data** - MIT-licensed sets vendored under `policies/` (see `policies/README.md` and `policies/LICENSE.opencode-policy` for provenance)
- **Docker CLI** - Apache 2.0 License (packaged in container)
- **Node.js** - MIT License (packaged in container)

## 🤝 Contributing

Contributions are welcome! Here's how you can help:

1. **Fork the repository**
2. **Create a feature branch** (`git checkout -b feature/amazing-feature`)
3. **Make your changes** and test them (`node tests/claude-guard.test.mjs`, `bash tests/wrapper-args.test.sh`)
4. **Commit your changes** (`git commit -m 'Add amazing feature'`)
5. **Push to the branch** (`git push origin feature/amazing-feature`)
6. **Open a Pull Request**

### Guidelines

- Follow existing shell script style (see [AGENTS.md](AGENTS.md) for conventions)
- Test changes with both `claude-dockerized` and `run-simple.sh`
- Update documentation for new features
- Keep security as a priority

---

**Made with 🔒 by developers who like AI but trust carefully**
