# Claude Dockerized - Secure Sandbox Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Run [Claude Code](https://code.claude.com/docs) (native binary, pinned version) inside a sandboxed Docker container that sees only the project you give it. The agent stays useful; the blast radius stays small.

## Table of Contents

- [Security Features](#-security-features)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Usage](#-usage)
- [Multiple accounts (profiles)](#-multiple-accounts-profiles)
- [Configuration](#-configuration)
- [Portability & Sharing](#-portability--sharing)
- [Advanced Usage](#-advanced-usage)
- [Updates, trust and rollback](#-updates-trust-and-rollback)
- [Hardening profiles and session integrity](#️-hardening-profiles-and-session-integrity)
- [Troubleshooting](#-troubleshooting)
- [File Reference](#-file-reference)
- [Additional Resources](#-additional-resources)
- [Important Notes](#️-important-notes)
- [Performance Optimizations](#-performance-optimizations)
- [Testcontainers Support](#-testcontainers-support)
- [License](#-license)
- [Contributing](#-contributing)

## 🔒 Security Features

### Isolated by default

- **The container is the boundary.** A session only sees the project directory you pass to `run`.
- **No root, no privileges.** It runs as your host UID/GID (`--user`) with `--cap-drop=ALL` and `no-new-privileges`; the image ships no privilege-escalation binary.
- **No Docker control unless you ask.** The host Docker socket is not mounted by default (`setting.docker_socket=true` opts in; it is root-equivalent on the host).
- **Small blast radius.** `rm -rf .` destroys the mounted project, not your home.

### A security layer the session cannot relax

- **Managed policy, highest precedence.** `permissions.deny/ask`, `allowManagedHooksOnly`, `disableBypassPermissionsMode` and `DISABLE_AUTOUPDATER=1` reach the container read-only as `/etc/claude-code/managed-settings.json`, so user and project settings cannot weaken them.
- **Fail-closed hooks.** Two native `PreToolUse` hooks (Bash, and every file tool) block whatever they cannot evaluate, backed by vendored pattern sets for destruction, exfiltration, secrets and Docker escapes.
- **Configurable policy.** `setting.security_policy` selects `strict`, `balanced` (default: drops the noisy cloud/multi-tenant rules) or `none` (built-in backstops only).
- **Remote flows keep working.** Git over SSH, remote MCP servers (`http`/`sse`), registries and APIs stay allowed in every mode.
- **No auto-updates.** The pinned Claude Code version (`2.1.311`) runs until *you* run `claude-dockerized update`, which verifies a signed release first.

### State that survives without touching your host

- **One self-contained home.** Login, sessions, MCP state, plugins and LSP servers live under `~/.config/claude-dockerized/profiles/<name>/home/`, so they survive restarts and image rebuilds.
- **The host stays clean.** `~/.claude`, `~/.local/...`, `~/.ssh` and `~/.gnupg` are never mounted. Agents are forwarded through sockets and only public GnuPG material is copied.
- **Changes are reported.** After every session the wrapper fingerprints the persistent paths a session could plant code in and lists what changed (see [Hardening profiles and session integrity](#️-hardening-profiles-and-session-integrity)).

## 📋 Prerequisites

- **Docker**, installed and running. Nothing else: no local Claude Code, Node.js or Python toolchain is needed on the host.
- **Optional**, mounted only if you ask for it: `~/.gitconfig` (see [Custom configuration](#custom-global-configuration-optional)).

## 🚀 Quick Start

### First-Time Setup

```bash
# 1. Install. Recommended: download, inspect, then run
curl -fsSLO https://raw.githubusercontent.com/yukiteruamano/claude-dockerized/master/install.sh
less install.sh && bash install.sh
#    (one-liner: curl -fsSL .../install.sh | bash; from a clone: ./install.sh)
#    Non-interactive: ./install.sh --yes · only some steps: ./install.sh --only completions,aliases
#    Pin a release: CCODE_REF=v0.4.5 bash install.sh

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
# - Save credentials to ~/.config/claude-dockerized/profiles/default/home/.claude/.credentials.json on your host
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

`claude-dockerized help <command>` (or `<command> --help`) prints one command's details. Global options: `-p/--profile NAME`, `--no-color`, `-V/--version`.

#### Everyday

```bash
claude-dockerized run [DIR]        # Run Claude Code (default: current dir); args after -- go to claude
claude-dockerized exec "..."       # Non-interactive prompt (claude -p)
claude-dockerized auth             # Log in (claude auth login)
claude-dockerized update [--check] # Verified self-update (exit: 0 up to date, 100 available, 1 error)
claude-dockerized rollback         # Undo the last update (checkout + previous image)
claude-dockerized doctor [--json]  # Host + container checks, exit 1 on failure
```

#### Accounts and inspection

```bash
claude-dockerized profiles                 # name, login, account, model, last use, size
claude-dockerized profile --help           # create, login, use, bind, set, rename, delete, doctor, migrate
claude-dockerized models                   # Effective default model
claude-dockerized mcp list                 # MCP servers and their status (login/logout work here)
claude-dockerized plugin list              # Loaded plugins (install/update/remove are host-only)
claude-dockerized stats                    # Local session-storage statistics
claude-dockerized debug paths              # Resolved generated-home paths
claude-dockerized debug doctor             # Native claude doctor inside the container
claude-dockerized version [--json]         # Wrapper, guard, policy and Claude Code versions (no Docker needed)
```

#### Image and configuration

```bash
claude-dockerized install                  # Install / repair PATH, config, completions, aliases
claude-dockerized build [--no-cache|--pull] # Build the image
claude-dockerized config show              # Parsed configuration
claude-dockerized config edit              # Edit the wrapper config in $EDITOR
claude-dockerized config path              # Config file path
claude-dockerized config sync [--check]    # Refresh the security layer (hooks/policies/settings)
claude-dockerized config claude [path|edit|policy]  # User settings.json (writable) / managed policy path
claude-dockerized config credentials path  # Credentials file path (values never printed)
claude-dockerized clean                    # Remove the Docker image and stale relays
claude-dockerized help [COMMAND]           # Overview, or one command's details
```

`run` passes everything after `--` to Claude Code: `claude-dockerized run . -- --resume`.
Its exit status is Claude Code's own.

### Dry Run Mode

Preview the `docker run` command without executing it:

```bash
DRY_RUN=true claude-dockerized run /path/to/project
```

The full command is printed one flag per line, with every mount and environment variable — useful for debugging configuration issues. Secrets travel via `--env-file`, so only the file path is shown.

Output is plain when it is not a terminal; `--no-color`, `NO_COLOR=1` or `TERM=dumb` force plain output and `CLICOLOR_FORCE=1` forces color. Warnings and errors go to stderr.

### Alternative Runners

```bash
./run-simple.sh /path/to/your/project
```

### Inside the Container

Once Claude Code starts, use it as usual (`/model` to switch models, `/mcp` for MCP servers, `/hooks` to inspect hooks, `/status` to confirm settings loaded).

## 👥 Multiple accounts (profiles)

Each Claude account is a **profile** with its own home (login, sessions,
plugins, MCP servers), its own config overlay and its own secrets file. Only
the active profile's home is ever mounted, so a session cannot read another
account's state.

```bash
ccd profile create work --login      # create the profile and log in (in the container)
ccd run ~/code/app --profile work    # use it (also: -p work, CLAUDE_DOCKERIZED_PROFILE=work)
ccd profiles                         # name, login, account e-mail, model, last use, size
ccd profile use work                 # make it the default
ccd profile bind work ~/code/app     # always use it for this project (kept outside the project)
```

Everything you had before is the `default` profile. The first command after
the upgrade migrates the old layout into `profiles/default/` automatically:

- **A backup comes first**, in `~/.config/claude-dockerized/backups/pre-profiles-<time>/` (`0700`). If it cannot be written (for example, no disk space), nothing is changed and the command says why.
- **Preview or undo:** `profile migrate --dry-run` shows the move, `profile migrate --rollback` undoes it, and `claude-dockerized rollback` to a version that predates profiles reverts it for you (it refuses while other profiles exist).
- **`--no-backup`** migrates without copying data, but still writes the record `--rollback` needs.
- **The backups hold the credentials of that moment.** Delete them with `profile migrate --prune-backups` when you no longer need them (`logout` and `delete` of `default` remind you).

```text
~/.config/claude-dockerized/
├── config                 global settings
├── profiles/<name>/
│   ├── home/              the profile's Claude state (the only home mounted)
│   ├── config             overlay: setting.* and mount.* override the global config
│   └── env                the profile's secrets (dotenv, chmod 600, never mounted)
└── profiles.map           project -> profile binds
```

| Command | What it does |
| --- | --- |
| `profile list [--json]` / `profiles` | all profiles with login state and account |
| `profile create NAME [--from SRC] [--login] [--model M] [--env-file F] [--share-skills] [--lsp-from default]` | new profile (`--from` copies preferences, never credentials) |
| `profile login NAME` / `logout NAME` | log in / drop the OAuth login |
| `profile show [NAME]`, `path`, `current` | inspect |
| `profile use NAME`, `bind NAME [DIR]`, `unbind [DIR]` | choose the default / pin a project |
| `profile edit NAME [config\|env\|rules]`, `set`, `unset` | change the overlay, the secrets or the profile's session rules |
| `profile rename`, `delete NAME [--yes]` | manage (refused while a session runs) |
| `profile doctor [NAME]`, `migrate` | checks, layout migration |

**Which profile runs?** `--profile`/`-p`, then `CLAUDE_DOCKERIZED_PROFILE`, then
the project bind, then `setting.profile`, then `default`.

**Secrets are per profile.** There is no global env file: API keys go in
`ccd profile edit NAME env`, because a global key could override another
account's login. A profile that logs in with OAuth should not have
`ANTHROPIC_API_KEY` in its env file.

**Security.** A profile may tighten any setting freely. Loosening the global
security posture needs an explicit approval:

```bash
ccd profile set NAME KEY VALUE --allow-loosen
```

The approval stores the exact value, so editing the value afterwards voids it.
An unapproved loosening in the overlay file is ignored (one warning per run)
and `profile doctor` fails on it; `profile list` flags it with ⚠.

What counts as loosening:

- `security_policy` or `hardening` lowered;
- `docker_socket`, `ssh_agent_support`, `gpg_agent_support` (or the main-socket fallback) enabled;
- `integrity_check=false`;
- `share_skills=true` or `lsp_from=default` — the only two ways a profile reads another profile's files (`create --share-skills` / `--lsp-from` write their approval for you);
- a `host` network where the global one is `bridge` (the default);
- a `memory`/`cpus` limit removed or raised;
- any `:rw` mount: `profile set NAME mount.<name> HOST:CONTAINER:rw --allow-loosen`.

Read-only mounts need no approval (the overlay is a file only you edit, and
credential directories are refused anyway), so a profile can mount an extra
read-only directory such as its own `.gitconfig`. A profile drops a global
mount with `ccd profile set NAME mount.<name> -` (removing access needs no
approval), e.g. to keep the work `.gitconfig` out of a personal profile.
`ccd profile edit NAME rules` writes `profiles/<name>/CLAUDE.md`: its text is
added after the global session rules (under `## Profile rules (<name>)`) in
the read-only `CLAUDE.md` that profile's sessions read; it cannot replace the
global rules, and like them it lives outside every mount.
`ccd profile edit NAME permissions` writes `profiles/<name>/permissions`, one
`deny RULE` or `ask RULE` per line (e.g. `deny WebFetch`,
`ask Bash(npm publish *)`); the rules are merged into that profile's managed
policy. There is no `allow`: a profile can only add restrictions, and an
invalid line is skipped with a warning.

A profile can run its own Claude Code release:
`ccd profile set NAME claude_version 2.1.300`, then
`ccd build --profile NAME` builds `claude-dockerized:claude-2.1.300` (its
binary sha256 is recorded and enforced like any version), and that
profile's sessions use it. `update` and `rollback` only touch the shared
image; `clean` also removes the per-profile images.

A profile can also carry its own guard allow rules (T-36), in the format of
`policies/allow-patterns.json`: `ccd profile edit NAME allow-patterns`, then
`ccd profile approve NAME allow-patterns` to review and pin them. The
approval stores the file's sha256, so any edit voids it until approved
again; unapproved rules are ignored with a warning. An allow rule only skips
the vendored deny rules — the built-in backstops still run — and the rules
are appended to the global ones in that profile's mirror only.
`share_skills=true` and
`lsp_from=default` mount the default profile's skills and `.local/bin`
read-only instead of duplicating them; `lsp_from` only helps once the default
profile installed the binaries, and sessions of that profile can write the
directory — hence the approval. Other per-profile settings: `model`, LSP and
formatters. The statusline shows `[profile] project`, seeded into every new
`settings.json`.

**What profiles do not isolate.**

- **The project directory** is shared: sessions of different accounts read and write the same files, including the project's own `.claude/` and `CLAUDE.md`.
- **`~/.agents`** is mounted read-only for every profile.
- **`CCODE_HOME` in your shell** pins the state root and turns profiles off (advanced use and the test seam).
- **The managed `CLAUDE.md`** is regenerated by the first run after the upgrade (the previous copy is kept as `CLAUDE.md.bak`).

## 🔧 Configuration

### Configuration File

The wrapper is configured through `~/.config/claude-dockerized/config`
(INI-style; `./install.sh` creates it, `config edit` opens it).

There is **no `.env` file**:

- **Secrets live per profile**, in `~/.config/claude-dockerized/profiles/<name>/env` (edit it with `ccd profile edit <name> env`). The file is passed with `docker --env-file`, so values never appear on the command line, and it is never mounted.
- **The wrapper refuses to start** while that file is readable by group or others. Keep it at `chmod 600`.
- **Passed automatically:** `TERM` and the forwarded agent sockets. Anything else needs an explicit entry.
- **No UID mapping:** the container runs as your host UID/GID (`--user`), so there is no `HOST_UID`/`HOST_GID` to set.

### Volume Mounts

| Host Path | Container Path | Mode | Purpose |
| --- | --- | --- | --- |
| `$PROJECT_DIR` | `$PROJECT_DIR` (with `$HOME` stripped) | read-write | Your project files |
| `~/.config/claude-dockerized/profiles/default/home/etc/claude-code/` | `/etc/claude-code/` | **read-only** | Managed policy `managed-settings.json` (permissions, hooks, no-autoupdate), highest precedence |
| `~/.config/claude-dockerized/profiles/default/home/.claude/` | `/home/coder/.claude/` | read-write | User settings (`/model`, `/config`), credentials (`0600`), plugins, agents, commands, `.lsp.json`, memory |
| `~/.config/claude-dockerized/profiles/default/home/.claude/skills/` | `/home/coder/.claude/skills/` | **read-only** | User skills (overlay); install and edit them from the host |
| `~/.config/claude-dockerized/profiles/default/home/.claude/hooks-guard/` | `/home/coder/.claude/hooks-guard/` | **read-only** | Native `PreToolUse` hooks + policy data (overlay) |
| `~/.config/claude-dockerized/profiles/default/home/.claude/CLAUDE.md` | `/home/coder/.claude/CLAUDE.md` | **read-only** | Managed session rules (overlay) |
| `~/.config/claude-dockerized/profiles/default/home/.claude.json` | `/home/coder/.claude.json` | read-write | MCP user-scope state |
| `~/.config/claude-dockerized/profiles/default/home/.local/bin/` | `/home/coder/.local/bin/` | read-write | LSP/formatter binaries |
| `~/.config/claude-dockerized/profiles/default/home/.local/` (`share/claude`, `state/claude`, `cache/claude`) | `/home/coder/.local/` | read-write | Sessions, history, caches |
| `~/.config/claude-dockerized/profiles/default/home/.mcp-auth/` | `/home/coder/.mcp-auth/` | read-write (`0700`) | OAuth tokens of `mcp-remote` proxy servers (native Claude MCP OAuth lives in `.credentials.json`); the host `~/.mcp-auth` is never shared |
| `~/.config/claude-dockerized/profiles/default/home/.gnupg-sessions/<pid>/` | `/home/coder/.gnupg/` | read-write | Per-session mirror of the **public** GnuPG material + agent socket (only with `setting.gpg_agent_support=true`, one directory per session, removed when it ends); `private-keys-v1.d/` is never copied |

The wrapper's own directory (`~/.config/claude-dockerized/`) is **not** mounted at all, and `~/.claude` is never mounted as a whole. Managed files travel through fine-grained read-only mounts; state is mounted read-write.

### Multiple concurrent sessions

Several `claude-dockerized run` sessions can run at the same time, on the
same profile or on different ones. What they share is read-only or per-session:

- **Forwarded agents are per session.** `gpg_agent_support` mirrors the public
  GnuPG material into `profiles/<name>/home/.gnupg-sessions/<pid>/` (the
  container's keyboxd runs on its own copy) and relays the agent socket through
  `agent-relay/<pid>-gnupg/`; `ssh_agent_support` relays through
  `agent-relay/<pid>-ssh/`. A session only ever removes its own directories,
  and directories left by a crash (or by a previous boot) are cleaned up by the
  next run. Both agents are the host's, so all sessions use the same keys.
- **The SSH agent socket is never copied or written**, and `~/.ssh/config` and
  `~/.ssh/known_hosts` are mounted read-only: concurrent sessions cannot
  corrupt them.
- **The profile home is shared**, as before: `.claude.json`, `settings.json`
  and `.credentials.json` are read-write for every session of that profile.
  Two sessions of the same profile can therefore race on preference changes
  and on the OAuth refresh; use one profile per concurrent session if that
  matters.
- **One pinentry at a time.** The host gpg-agent serves many clients, but a
  passphrase prompt cannot be answered twice at once. Cache the key (or set
  `default-cache-ttl`) so concurrent sign/commit does not block on it.

See `docs/security/THREAT-MODEL.md` (T-35) for the threat this isolates.

### Persistent Configuration & Security Layer

The wrapper is **self-contained**: it replaces native host usage instead of
sharing it. Claude Code's whole state lives under one host directory
(`~/.config/claude-dockerized/profiles/<name>/home/`), which mirrors the
container home layout. Copy that directory and the setup travels with you; the
host XDG dirs (`~/.claude`, `~/.local/...`) are never touched.

```text
~/.config/claude-dockerized/
├── config                        ← wrapper INI config (settings, mounts)
├── profiles.map                  ← project -> profile binds (0600)
├── trust                         ← release keys you pinned (update)
├── state                         ← rollback point of the last update
├── audit/sessions.jsonl          ← one integrity record per session
├── backups/pre-profiles-*        ← layout-migration backup (0700, old logins)
├── CLAUDE.md                     ← session rules source
├── hooks/claude-guard-*.sh       ← hook sources (versioned in the repo)
├── hooks/guard-eval.js           ← policy evaluator source
├── hooks/policies/*.json         ← policy pattern sets + local allowlist
├── agent-relay/<pid>-<kind>/     ← per-session agent relay sockets (gnupg, ssh)
└── profiles/<name>/
    ├── config                    ← overlay: setting.* / mount.* overrides
    ├── env                       ← secrets dotenv (0600, never mounted)
    └── home/                     ← mirrors /home/coder, mounted piece by piece
        ├── etc/claude-code/managed-settings.json  ← GENERATED policy (ro) — do not edit
        ├── .claude/                               ← rw mount
        │   ├── settings.json                      ← your preferences, seeded; /model and /config write here
        │   ├── .credentials.json                  ← login, 0600
        │   ├── hooks-guard/                       ← mirrored hooks + policies, ro
        │   ├── CLAUDE.md                          ← mirrored rules, ro
        │   ├── plugins/ agents/ commands/         ← yours, rw
        │   ├── skills/                            ← yours, ro (edit from the host)
        │   └── .lsp.json                          ← generated with setting.lsp=true
        ├── .claude.json                           ← MCP state, rw
        ├── .local/bin/                            ← LSP/formatter binaries, rw
        ├── .local/share|state/claude/ .cache/claude/  ← sessions, history, caches, rw
        ├── .mcp-auth/                             ← MCP proxy OAuth tokens, 0700
        └── .gnupg-sessions/<pid>/                 ← per-session GnuPG mirror (opt-in)
```

Because everything lives on the host, state persists across `docker` up/down
cycles **and** image rebuilds.

- **Editing.** The policy is mounted **read-only**: change wrapper settings on the host (`claude-dockerized config edit`, then `config sync`). Your preferences are writable — use `/model` or `/config` in a session, or `claude-dockerized config claude edit`.
- **Host-only commands.** `claude mcp add/remove` and `claude plugin install/update/remove` are disabled inside the container. `claude mcp login/logout` keep working (tokens live in read-write mounts); the wrapper's `mcp`/`plugin` commands expose what is safe.
- **Security layer.** Generated on the host from the repo copy and mirrored on every run. The hooks are versioned (`hooks/claude-guard-*.sh`); bumping `CLAUDE_DOCKERIZED_GUARD_VERSION` refreshes installs, keeping the previous copy as `.bak`.
- **Policy mode.** `setting.security_policy` (default `balanced`) selects what the hooks enforce: `balanced` drops cloud/multi-tenant rules and common false positives, `strict` enforces everything, `none` keeps only the built-in backstops. Local exceptions live in `hooks/policies/allow-patterns.json`.
- **No auto-updates.** `env.DISABLE_AUTOUPDATER=1` is always set in the managed policy (check with `claude-dockerized doctor`, which also runs the native `claude doctor`). Upgrades go through `claude-dockerized update`, which rebuilds with the pinned `CLAUDE_CODE_VERSION` (`2.1.311`; override with `update --claude-version X.Y.Z`).

### Custom Global Configuration (Optional)

Settings and mounts apply to every project of the profile. The common ones:

- **SSH agent forwarding** — `setting.ssh_agent_support=true` (recommended for git over SSH). Only the host `SSH_AUTH_SOCK` is forwarded; `~/.ssh/config` and `known_hosts` are mounted read-only and private keys are never mounted.
- **GnuPG agent forwarding** — `setting.gpg_agent_support=true` signs commits (`git commit -S`) with the keys in your host gpg-agent. Private keys never enter the container. Verify with `claude-dockerized doctor`.
- **Global git configuration** — mount `~/.gitconfig` (see the examples below).
- **Default model** — `setting.model=sonnet` (passed as `--model`; `/model` still works per session).
- **LSP servers** — `setting.lsp=true` plus `setting.lsp_servers=go,ts,python,rust` installs them into the generated home and writes `.lsp.json`.
- **Formatters** — `setting.formatters=true` installs the formatters and enables their plugins.

#### Config Format

```ini
# Settings (see examples/config.example for the full list)
setting.ssh_agent_support=true
setting.gpg_agent_support=true
setting.gpg_allow_main_socket=false
setting.gpg_autostart_agent=true
setting.memory=4g
setting.cpus=2
setting.profile=default
setting.model=sonnet
setting.cleanup_days=7
setting.lsp=false
setting.lsp_servers=ts,python
setting.formatters=false

# Custom volume mounts (read-only by default)
# Format: mount.<name>=<host_path>:<container_path>[:rw]
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig

# Secrets go in the profile's env file (ccd profile edit NAME env; dotenv KEY=VALUE, mode 600), e.g.:
#   ANTHROPIC_API_KEY=...
#   CLAUDE_CODE_OAUTH_TOKEN=...
```

Common setups:

#### Example 1: Git configuration with SSH agent forwarding (recommended)

```ini
setting.ssh_agent_support=true
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
```

Private keys never enter the container: only `SSH_AUTH_SOCK` and the non-secret `~/.ssh/config` / `known_hosts` are shared read-only. Mounting `~/.ssh` is refused.

#### Example 2: Commit signing with the host GnuPG agent

```ini
setting.gpg_agent_support=true
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
```

Inside the container, point git at your key (`git config --global user.signingkey <KEYID>` and `commit.gpgsign true`). Only the public keyring and the host `gpg-agent` socket are shared; private keys stay on the host. The restricted `S.gpg-agent.extra` socket is preferred. Verify with `claude-dockerized doctor`.

Two details that surprise people:

- **Socket relay.** Many Docker setups cannot bind a socket that lives on a per-user tmpfs (`/run/user/<uid>/...`), where `gpg-agent` and common SSH agents keep theirs. The wrapper then relays it through a socket on a normal filesystem (`~/.config/claude-dockerized/agent-relay/<pid>-<kind>/`) with `socat`, and mounts the relay. Install `socat` on the host; without it you get a warning and the raw socket is mounted.
- **Pinentry** runs on the **host** agent, so it is independent of the container's desktop.

#### Example 3: API keys (per-profile secrets file)

```bash
ccd profile edit work env      # creates ~/.config/claude-dockerized/profiles/work/env (chmod 600)
```

Add one `KEY=VALUE` per line. The file is passed with `docker --env-file`, so values never appear on the command line; the file itself is never mounted, and a profile never sees another profile's file.

#### Example 4: LSP servers

```ini
setting.lsp=true
setting.lsp_servers=ts,python
```

Binaries install into `~/.config/claude-dockerized/profiles/default/home/.local/bin/` (on `PATH` in the container) and `.lsp.json` is generated. Everything persists across rebuilds. Check with `claude-dockerized doctor`.

#### Notes

- **Never mount `~/.ssh` or `~/.gnupg`**: both are refused. Forward the agents instead (`setting.ssh_agent_support`, `setting.gpg_agent_support`).
- **Several sessions can share one agent**: each session forwards the same host agent through its own relay, and GnuPG gets its own mirror of the public material.
- **Mounts are read-only by default**; append `:rw` for read-write.
- **`~` expands** to your home directory at run time.
- **Re-run `./install.sh`** any time to refresh your configuration.

## 🌍 Portability & Sharing

The wrapper is portable by design: it resolves everything from `$HOME`, and all
of its state lives in one directory.

- **Move machines:** copy `~/.config/claude-dockerized/`, then re-run `./install.sh` on the target and rebuild the image.
- **New machine:** `curl -fsSLO .../install.sh`, inspect it, `bash install.sh`, `claude-dockerized build`, `claude-dockerized auth`, `claude-dockerized run`.
- **Reinstall/repair:** `claude-dockerized install` is idempotent; `config sync` refreshes the security layer from the repo.
- **No host toolchain:** Docker is the only requirement; Claude Code, Node.js and Python tooling live in the image.

### Platform Compatibility

| Platform | Status |
| --- | --- |
| Linux | works out of the box |
| macOS | works with Docker Desktop |
| Windows (WSL2) | works from the WSL2 terminal |
| Windows (native) | use WSL2 instead |

### What to Share

**Safe to share** — no secrets, no personal state: the `Dockerfile`, `install.sh` and the other scripts, the hooks and policies, and the docs.

**Never share** — everything under your own state:

- a profile's `env` file and `.credentials.json` (your logins);
- `~/.config/claude-dockerized/profiles/<name>/home/` (sessions, plugins, MCP state);
- `.mcp-auth/` (OAuth tokens of MCP proxy servers);
- `backups/pre-profiles-*` (they keep the credentials of that moment).

None of these live in the repo: the wrapper writes them under `$CONFIG_DIR` with `0600` and never mounts that directory.

## 🔍 Advanced Usage

### Python Development with uv

The container includes [uv](https://docs.astral.sh/uv/), a fast Python package manager:

```bash
uv init my-project              # Create a new Python project
uv add requests                 # Add dependencies
uv run python script.py         # Run scripts in isolated environment
```

### Adding Additional Tools

System packages belong in the image, so edit the `Dockerfile` (one `RUN` layer,
cache cleaned in the same layer) and rebuild:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    some-tool \
    && rm -rf /var/lib/apt/lists/*
```

```bash
claude-dockerized build
```

Language tooling that you want to keep across rebuilds (LSP servers,
formatters) does not belong in the image: install it with `setting.lsp` /
`setting.formatters`, or drop it in the generated home's `.local/bin`.

### Pinned Claude Code version

```dockerfile
# Default (repo-pinned), with the checksums of that release's manifest
ARG CLAUDE_CODE_VERSION=2.1.311
ARG CLAUDE_CODE_MANIFEST_VERSION=2.1.311
ARG CLAUDE_CODE_MANIFEST_SHA256_X64=86dc1fcc…
ARG CLAUDE_CODE_MANIFEST_SHA256_ARM64=2e2496c9…
```

Maintainers bump all four together: the values are the `linux-x64` /
`linux-arm64` checksums of
`https://downloads.claude.ai/claude-code-releases/<version>/manifest.json`
(`tests/supply-chain.test.sh` fails when the versions drift apart). Any other
version is trusted on its first build and recorded; set
`setting.require_claude_sha=true` to refuse that unless
`build --trust-first-use` accepts it.

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
| --- | --- |
| `update --check` | 0 up to date · 100 update available · 1 error |
| `update`, `rollback`, `build` | 0 success · 1 error |
| `doctor` | 0 all checks pass · 1 any check failed |
| `run`, `exec` | Claude Code's own exit status |

## 🛡️ Hardening profiles and session integrity

Defaults keep the runtime unchanged. Opt in with `setting.hardening`:

| Profile | Adds |
| --- | --- |
| `off` (default) | — |
| `standard` | `--init`, `--pids-limit 4096`, private IPC |
| `strict` | standard + read-only root filesystem (tmpfs for `/tmp` and caches), read-only plugins / agents / commands / `~/.local/bin` and project `.git` hooks/config (skills are read-only in every profile) |

Image options: `setting.image_strip_setuid=true` (no setuid bits),
`setting.image_docker_cli=false` (no Docker CLI; only useful with the socket).

After every `run`, the wrapper compares fingerprints of the persistent paths a
session could plant code in (project git hooks/config and Claude settings,
`~/.local/bin`, plugins, skills, MCP servers) and lists every
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
# Is the daemon running?
docker info

# Leftover containers? Names are claude-<project>-<suffix> (or claude-<profile>-...)
docker ps -a --filter name=claude-

# Rebuild the image and re-run the checks
claude-dockerized build
claude-dockerized doctor
```

### "GnuPG agent socket not available"

- Launch the agent: `gpgconf --launch gpg-agent` (or leave `setting.gpg_autostart_agent=true`, the default, which does it for you).
- The restricted `S.gpg-agent.extra` socket is preferred; the full-control socket needs `setting.gpg_allow_main_socket=true`.
- If the socket lives under `/run/user/<uid>/`, the relay needs `socat` on the host.

### "Could not start the ... relay"

Install `socat` on the host (`apt install socat`, `brew install socat`) and re-run. Without it the agent socket is mounted directly, which fails on a `/run/user/<uid>` tmpfs.

### Leftover session directories

- `claude-dockerized clean` drops stale relays.
- Per-session GnuPG mirrors (`profiles/<name>/home/.gnupg-sessions/`) are removed when their session ends, and purged by the next run when the PID is gone or belonged to a previous boot. They are safe to delete by hand while no session runs.

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

Your login lives in `~/.config/claude-dockerized/profiles/<name>/home/.claude/.credentials.json` (`config credentials path` prints the exact path). If it is missing, re-run `claude-dockerized auth`. Run `claude-dockerized doctor` first if you are not sure what broke.

### Two sessions interfere with each other

They should not: agents are forwarded per session (see [Multiple concurrent sessions](#multiple-concurrent-sessions)). What is still shared is the profile home — two sessions of the *same* profile share `.claude.json`, `settings.json` and the login — so use one profile per concurrent session if you see preference or re-login churn.

## 📁 File Reference

### Core Files

- **`Dockerfile`** - Container image definition (Debian trixie-slim + Node.js/NVM + pnpm + uv + Claude Code native binary v2.1.311, no sudo, no npm)
- **`entrypoint.sh`** - Container entrypoint (resolves the workdir, sets up NVM/Node and execs the command; runs unprivileged, no UID/GID mapping)

### User Scripts

- **`bin/claude-dockerized`** - Main wrapper, no extension (run, exec, auth, mcp, plugin, build, update, rollback, doctor, version, config, clean, help, ...). Reached via `<install>/bin` on `PATH`; `bin/` holds only this binary
- **`install.sh`** - Curl-able bootstrap (runs the local `bin/claude-dockerized install`, or clones to `~/.local/share/claude-dockerized` first; full setup in one shot)
- **`run-simple.sh`** - Simplified runner script (delegates to `claude-dockerized run`)

### Shared Modules

- **`lib/config-lib.sh`** - Entry point of the shared library: constants, `parse_config`/`print_config` and image helpers; sources the modules below. Sourced by every script; not executable directly
- **`lib/config-file-lib.sh`** - The config file: settings, loading (global file and profile overlays), saving
- **`lib/mount-validate-lib.sh`** - The single path validator: custom mounts, sensitive host paths, container targets, project directory
- **`lib/mounts-lib.sh`** - `docker run` arguments: mount plan, env, network, hardening profiles
- **`lib/layer-lib.sh`** - Security layer: managed policy and settings generation, hooks/policies mirror, sync and checks
- **`lib/agent-lib.sh`** - Forwarded GnuPG/SSH agents: per-session public GnuPG mirror, agent socket resolution and the socket relay
- **`lib/profile-lib.sh`**, **`lib/profile-overlay-lib.sh`**, **`lib/profile-migrate-lib.sh`** - Account profiles: selection and per-profile home; the config overlay with the loosening guard, allow and permission rules; the legacy migration
- **`lib/profile-cmd-lib.sh`**, **`lib/profile-edit-lib.sh`** - The `profile`/`profiles` commands; `edit`/`set`/`unset`/`approve` and overlay validation
- **`lib/lsp-lib.sh`** - Opt-in LSP servers and formatters (installed into the generated home)
- **`lib/wizard-lib.sh`** - Interactive configuration prompts
- **`lib/install-lib.sh`** - Install wizard library sourced by the wrapper's `install` command
- **`lib/update-lib.sh`** - Verified self-update (trust store, signature checks, origin pin, rollback)
- **`lib/integrity-lib.sh`** - Session integrity check and audit log
- **`lib/ui-lib.sh`**, **`lib/help-lib.sh`**, **`lib/diag-lib.sh`** - Output helpers, help texts, Docker preflight / doctor / version
- **`lib/migrate-settings.js`** - Node helper that strips policy keys from a legacy `settings.json`
- **`lib/merge-allow-patterns.js`** - Node helper that validates a profile's guard allow rules and merges them after the global ones
- **`lib/doctor-container.sh`** - Diagnostics run inside the container by `doctor`

### Security Layer

- **`hooks/claude-guard-bash.sh`**, **`hooks/claude-guard-file.sh`** - Versioned native `PreToolUse` hooks (Bash/file confinement, policy modes, backstops)
- **`hooks/guard-eval.js`** - Vendored-pattern evaluator used by the bash hook
- **`policies/unsafe-tool-patterns.json`**, **`policies/prompt-injection-patterns.json`** - Vendored pattern sets
- **`policies/allow-patterns.json`** - Local allowlist (e.g. `.env.example`)
- **`policies/VERSION`** - Mirror marker: a newer repo copy refreshes the installed one
- **`policies/README.md`** - Provenance and refresh instructions

### Tests

- **`tests/run-all.sh`** - Runs every suite (`--integration` adds the Docker runtime checks, `--verbose` lists known gaps, `--no-skip` fails on self-skipped suites)
- **`tests/*.test.mjs`** - Guard: regression cases, bypass corpus (`tests/fixtures/guard-corpus.json`), fail-closed behavior, policy data, hook wiring, settings merge
- **`tests/*.test.sh`** - Wrapper: docker argv, mounts, profiles, config parsing, hardening, integrity, self-update, supply chain, LSP installs, CLI/UI contract, threat-matrix traceability
- **`tests/integration/container.test.sh`** - Runtime contract inside the real image (skips without Docker)
- **`tests/lib/`** - Shared helpers (`assert.sh`, `hook-runner.mjs`); known gaps are XFAIL and turn red once fixed

### Shell Completion (`completions/`)

- **`completions/bash.sh`** - Bash shell completion script
- **`completions/zsh.sh`** - Zsh shell completion script

### Examples (`examples/`)

- **`examples/config.example`** - Example custom configuration file

### Documentation & Meta

- **`SECURITY.md`** - Security overview, known limitations, vulnerability reporting
- **`docs/security/`** - Threat model (T-01…T-35) with the Red (attacks), Blue (controls, detection, response) and Yellow (secure development) playbooks
- **`CONTRIBUTING.md`** - Contribution workflow and local checks (CI parity)
- **`AGENTS.md`** - Conventions for humans and agents working on the repo
- **`.shellcheckrc`**, **`.hadolint.yaml`**, **`.editorconfig`** - Linter/formatter configuration

### Configuration

- **`.gitignore`** - Excludes sensitive files from Git
- **`.dockerignore`** - Excludes non-essential files from Docker build context

### How It Works

1. **Base image** — Debian Trixie slim, pinned by digest.
2. **Docker CLI only** — no daemon; the host daemon is used through the opt-in socket, with no privileges.
3. **Development tools** — Node.js (via NVM), Python tooling (uv), git, jq, ripgrep and the usual CLI tools, all pinned.
4. **Claude Code** — the pinned native binary (`2.1.311`) from the official installer (`https://claude.ai/install.sh`), never npm.
5. **User** — a non-root `coder` user exists in the image, but the wrapper runs the container as *your* UID/GID (`--user`) and joins the `coder` group (`--group-add`), so no root process and no runtime remapping.
6. **Entrypoint** — resolves the project workdir, loads NVM/Node and execs the command unprivileged.
7. **Mounts** — only what is needed, with the right mode: managed files read-only, state read-write.

### The Blast Radius Concept

If Claude Code runs something dangerous like `rm -rf .`:

- **Without the container**: it could delete your entire home directory.
- **With the container**: it can only affect the project directory you mounted.

That is the whole point of the sandbox: full functionality, bounded damage.

## 📚 Additional Resources

- [Claude Code Documentation](https://code.claude.com/docs)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)

## ⚠️ Important Notes

1. **Docker socket (opt-in).** Never mounted by default. `setting.docker_socket=true` gives the session the host daemon, which is root-equivalent on the host: enable it only when you need it.
2. **Network.** `--network bridge` is the default since 0.5.0: services on the host's `localhost` are out of reach, and services the host publishes on its Docker bridge answer at `host.docker.internal`. `setting.network=host` restores the shared namespace (a profile needs `--allow-loosen` for it).
3. **Configuration.** The managed policy and hooks are mounted **read-only**: change wrapper settings on the host (`config edit`, then `config sync`). Auth and MCP OAuth live in read-write mounts, so `auth` and `mcp login` keep working.
4. **Persistence.** Project files and the whole `profiles/<name>/home/` state tree survive restarts and rebuilds.
5. **No privilege escalation.** The image ships no `sudo`, the container runs as your host user with all capabilities dropped and `no-new-privileges`, so it cannot become root inside.
6. **No self-updates.** Claude Code never updates itself in the container (`DISABLE_AUTOUPDATER=1`); use `claude-dockerized update`.
7. **Not a replacement for caution.** Review what the agent does, especially with permissive settings or the Docker socket enabled.

## 🚀 Performance Optimizations

The setup is built for minimal overhead:

- **Docker CLI only** — no daemon in the image (about 200 MB saved).
- **Host daemon, opt-in** — reuse the running daemon through the socket when `setting.docker_socket=true`; no Docker-in-Docker.
- **No privileged mode** — none of the `--privileged` machinery.
- **Shared image cache** — the image and layers are the host's.
- **Fast startup** — nothing to initialize; `docker run` and go.
- **Slim image** — LSP servers and formatters live in the generated home, not in the image.

## 🧪 Testcontainers Support

**Testcontainers support is opt-in.** Enable the host Docker socket first:

```ini
# ~/.config/claude-dockerized/config
setting.docker_socket=true
```

Your integration tests can then start containers — on the **host's** Docker daemon, not inside the Claude container. Remember that this socket is root-equivalent on the host.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

### Third-Party Software

This project uses and packages the following third-party software:

- **[Claude Code](https://code.claude.com/docs)** - Proprietary (Anthropic; downloaded at image build time, pinned version)
- **Policy pattern data** - MIT-licensed sets vendored under `policies/` (see `policies/README.md` and `policies/LICENSE.opencode-policy` for provenance)
- **Docker CLI** - Apache 2.0 License (packaged in container)
- **Node.js** - MIT License (packaged in container)

## 🤝 Contributing

Contributions are welcome.

1. **Fork** the repository and create a branch (`git checkout -b feature/amazing-feature`).
2. **Make your change** and run the checks: `bash tests/run-all.sh`, `uvx --from shellcheck-py shellcheck -x -S warning …`.
3. **Commit** (`git commit -m 'Add amazing feature'`) and **push** the branch.
4. **Open a Pull Request**.

### Guidelines

- Follow the conventions in [AGENTS.md](AGENTS.md): kebab-case scripts, snake_case functions, quoted variables, arrays for Docker arguments.
- Read [CONTRIBUTING.md](CONTRIBUTING.md) for the full check list (CI parity) and [docs/security/YELLOW.md](docs/security/YELLOW.md) before touching the hooks or the mount plan.
- Update the docs for user-visible changes: this README, [SECURITY.md](SECURITY.md) and the [threat model](docs/security/THREAT-MODEL.md) when you add or close a threat.
- Keep security the priority: never weaken a deny rule without a documented reason and a test.

---

**Made with 🔒 by developers who like AI but trust carefully**
