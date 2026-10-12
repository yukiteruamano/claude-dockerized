# Agent Guidelines for Claude Dockerized

## Project Overview

Shell script-based Docker wrapper for running [Claude Code](https://code.claude.com/docs) (native binary, pinned version) in secure, isolated containers. Sandboxes Claude Code so its blast radius is limited to the mounted project directory. Source is Bash scripts, a Dockerfile, two native `PreToolUse` hook scripts (`hooks/claude-guard-*.sh`) plus a small Node.js policy evaluator (`hooks/guard-eval.js`) with vendored JSON policy data (`policies/`), and Node-based policy tests (`tests/`). No package manager files and no build step.

**Key files:**
- `bin/claude-dockerized` — Main wrapper, no extension (build, run, auth, models, exec, mcp, plugin, stats, debug, doctor, version, install, uninstall, upgrade, update, rollback, config, clean, help commands). Reached via `<install>/bin` on PATH; nothing lives in `~/.local/bin`. `bin/` holds only this binary.
- `install.sh` — Curl-able bootstrap: runs the local `bin/claude-dockerized install` when present, else clones to `~/.local/share/claude-dockerized` and runs it there (full setup in one shot, no second manual install)
- `lib/config-lib.sh` — Entry point of the shared library: constants, output wrappers, config file parsing/saving (`load_config`, `save_config`, `init_config_file`), image/container helpers; it sources the five modules below. Sourced by every script. **Not executable directly.**
- `lib/mounts-lib.sh` — `docker run` arguments: standard volumes, custom mounts and their validation (`validate_mount_spec`, `sensitive_host_path_reason`, `container_path_reason`), project dir validation, env/env-file args, hardening flags. Sourced by `config-lib.sh`.
- `lib/layer-lib.sh` — The security layer: managed policy and user settings generation, hooks/policies mirror (`ensure_claude_dockerized_config`), `check_security_layer`, `sync_security_layer`. Sourced by `config-lib.sh`.
- `lib/agent-lib.sh` — Forwarded GnuPG/SSH agents, the public GnuPG mirror and the socket relay, `test_seam`. Sourced by `config-lib.sh`.
- `lib/lsp-lib.sh` — Opt-in LSP servers/formatters installed into the generated home (pinned versions live here). Sourced by `config-lib.sh`.
- `lib/wizard-lib.sh` — Interactive configuration prompts and `interactive_config_setup`. Sourced by `config-lib.sh`.
- `lib/ui-lib.sh` — Output helpers (`print_info`/`print_success` → stdout, `print_warning`/`print_error` → stderr; color only on a TTY, `NO_COLOR`/`--no-color`/`CLICOLOR_FORCE`, ASCII symbols outside UTF-8). Sourced by `config-lib.sh`. **Not executable directly.**
- `lib/update-lib.sh` — Verified self-update: local trust store (`$CONFIG_DIR/trust`), signature verification, origin pin, target selection, preview, rollback state (`$CONFIG_DIR/state`). **Not executable directly.**
- `lib/diag-lib.sh` — Docker preflight with remediation, host `doctor` checks (`--json`), `version`. **Not executable directly.**
- `lib/help-lib.sh` — `help [COMMAND]` / `<command> --help` texts. **Not executable directly.**
- `lib/doctor-container.sh` — Diagnostics run inside the container by `doctor` (passed as `bash -c`; never on the host)
- `lib/integrity-lib.sh` — Session integrity check: fingerprints persistent paths (project git hooks/config and Claude settings, `~/.local/bin`, plugins, skills, MCP servers) before/after each run and logs changes to `$CONFIG_DIR/audit/sessions.jsonl`. Sourced by `config-lib.sh`. **Not executable directly.**
- `lib/install-lib.sh` — Install wizard library sourced by the wrapper's `install` command (`--yes`, `--only config,completions,aliases,global[,path][,build]`). **Not executable directly.**
- `config/managed-settings.json`, `config/user-settings.default.json` — Managed policy template (rendered by `write_managed_settings`) and user-settings seed
- `lib/migrate-settings.js` — Node helper for `ensure_user_settings`: strips policy keys (and `disableAllHooks`) from a legacy `settings.json`, keeping the user's own keys
- `Dockerfile` — Container image (Debian trixie-slim + Node.js/NVM + pnpm + uv + Claude Code native binary v2.1.296, no sudo, no npm install)
- `entrypoint.sh` — Container entrypoint (unprivileged; resolves workdir, loads NVM, execs the command)
- `run-simple.sh` — Simplified alternative runner (delegates to `claude-dockerized run`)
- `hooks/claude-guard-bash.sh`, `hooks/claude-guard-file.sh` — Versioned native `PreToolUse` hooks (source of truth; copied into the user config by `lib/layer-lib.sh`)
- `hooks/guard-eval.js` — Vendored-pattern evaluator used by the bash hook (exact JS RegExp semantics)
- `policies/` — Vendored policy pattern sets + local `allow-patterns.json` (see `policies/README.md`)
- `tests/run-all.sh` — Runs every suite (`--integration` adds the Docker runtime test, `--verbose` lists known gaps)
- `tests/claude-guard.test.mjs` — Security-policy regression tests (a deny is exit 2 exactly)
- `tests/guard-bypass-corpus.test.mjs` + `tests/fixtures/guard-corpus.json` — Data-driven Red-team bypass corpus, tagged by threat id
- `tests/guard-failure-modes.test.mjs`, `tests/guard-tool-coverage.test.mjs`, `tests/guard-eval.test.mjs`, `tests/migrate-settings.test.mjs` — Guard fail-closed behaviour, hook wiring, policy data integrity, legacy settings migration
- `tests/wrapper-args.test.sh` — Wrapper mount/env contract test (no Docker)
- `tests/commands.test.sh` — models, stats, debug, exec, uninstall, upgrade/rollback help and wrapper-level refusals (project that would shadow the image, world-readable env file) via a docker stub
- `tests/wrapper-dryrun.test.sh`, `tests/mounts.test.sh`, `tests/config-parse.test.sh`, `tests/self-update.test.sh`, `tests/cli-contract.test.sh` — Full `docker run` argv via a docker stub, mount/path validation, config parsing, self-update against a local bare origin, help/completion drift
- `tests/integration/container.test.sh` — Container runtime contract (non-root, zero caps, no_new_privs, read-only mounts); skips without Docker
- `tests/threat-matrix.test.sh`, `tests/hardening.test.sh`, `tests/integrity.test.sh`, `tests/supply-chain.test.sh`, `tests/lsp-install.test.sh`, `tests/ui.test.sh`, `tests/entrypoint.test.sh` — Docs↔tests traceability, hardening profiles, session integrity, supply-chain pins, LSP installs, CLI output, entrypoint PATH
- `docs/security/` — THREAT-MODEL (T-01…T-30), RED, BLUE, YELLOW; `SECURITY.md` is the index
- `tests/lib/` — Shared helpers (`assert.sh`, `hook-runner.mjs`); known gaps are XFAIL and turn red once fixed
- `SECURITY.md`, `CONTRIBUTING.md` — Security model and contribution guide
- `examples/config.example` — Example user config (INI-style)
- `.dockerignore` — Excludes non-essential files from Docker build context
- Completion scripts: `completions/{bash,zsh}.sh`

## Build / Test / Lint Commands

```bash
# Core operations
./install.sh                              # install bin/ on PATH + config (or: curl .../install.sh | bash)
bin/claude-dockerized build             # Build Docker image (uses layer cache)
bin/claude-dockerized run [DIR]         # Run Claude Code (default: current dir)
bin/claude-dockerized auth              # Authenticate (claude auth login)
bin/claude-dockerized update --check     # 0 up to date, 100 update available, 1 error
bin/claude-dockerized update [--dry-run|--yes|--no-build|--channel tags|branch|--claude-version X]  # Verified update: signed tag, preview, ff, sync, rebuild
bin/claude-dockerized update --trust-key FILE  # Pin a release-signing key (interactive fingerprint confirmation)
bin/claude-dockerized rollback [--yes]  # Undo the last update (checkout + :prev image)
claude-dockerized models            # Show effective default model
claude-dockerized exec MSG          # Non-interactive prompt (claude -p)
claude-dockerized mcp [ARGS]        # Manage MCP servers (list|get|login|logout; add/remove are host-only)
claude-dockerized plugin [ARGS]     # Manage plugins (list|check; install/update/remove are host-only)
claude-dockerized stats             # Local session-storage statistics
claude-dockerized debug [ARGS]      # Debug helpers (paths|doctor, default: paths)
claude-dockerized doctor [--json]   # Host + container checks, summary, exit 1 on failure
claude-dockerized version [--json]  # Wrapper, guard, policy, pinned/image Claude versions (no Docker needed)
claude-dockerized help [COMMAND]    # Overview or one command's help (also: COMMAND --help)
claude-dockerized config show       # Show parsed configuration
claude-dockerized config edit       # Edit config in $EDITOR
claude-dockerized config path       # Print config file path
claude-dockerized config sync [--check]  # Refresh security layer (hooks/policies/settings) from repo
claude-dockerized config claude [path|edit|policy]  # User settings.json (writable) / managed policy path
claude-dockerized clean             # Remove Docker image
claude-dockerized help              # Show help
DRY_RUN=true claude-dockerized run  # Print docker command without running

# Validation
bash -n bin/claude-dockerized install.sh run-simple.sh  # Syntax-check key scripts
bash -n lib/*.sh completions/*.sh hooks/*.sh            # Syntax-check lib + completions + hooks
shellcheck -x -S warning bin/* lib/*.sh install.sh run-simple.sh entrypoint.sh completions/*.sh hooks/*.sh tests/*.sh tests/lib/*.sh tests/integration/*.sh   # Lint (config in .shellcheckrc)
cat Dockerfile | docker run --rm -i hadolint/hadolint:latest hadolint -   # Lint Dockerfile
node --check hooks/guard-eval.js    # Syntax-check the policy evaluator
node --check lib/migrate-settings.js  # Syntax-check the legacy settings migration helper
bash tests/run-all.sh               # Every suite (Node 22+, no Docker); --verbose lists known gaps, --no-skip fails on self-skipped suites
bash tests/run-all.sh --integration # + container runtime contract (needs Docker)
node tests/claude-guard.test.mjs    # Single suite, e.g. the security-policy regression tests
uvx --from shellcheck-py shellcheck -x -S warning bin/* lib/*.sh install.sh run-simple.sh entrypoint.sh completions/*.sh hooks/*.sh tests/*.sh tests/lib/*.sh tests/integration/*.sh   # ShellCheck without a local install

# Docker operations
docker build -t claude-dockerized:latest .                    # Manual build
docker build --no-cache -t claude-dockerized:latest .         # Force rebuild (no cache)
docker run --rm claude-dockerized:latest claude --version     # Verify version
```

`bash -n`, `shellcheck`, `hadolint`, `tests/run-all.sh`, a jq/python3-free guard job and the Docker integration job are what CI runs (`.github/workflows/ci.yml`, actions pinned by SHA). `shellcheck` is not installed in the container — use `uvx --from shellcheck-py shellcheck` or the `koalaman/shellcheck` image.

## Code Style Guidelines

### File Header

Every executable shell script starts with:
```bash
#!/bin/bash
set -e  # Exit on first error
```

**Exceptions:** every `lib/*.sh` file is a library sourced by callers — it must **not** use `set -e` to avoid affecting callers' error handling. The native hooks use `set -u` and exit 2 explicitly on every failure path (a hook that crashes with any other code fails open). `lib/doctor-container.sh` omits `set -e` on purpose so every check runs.

### Script Initialization

Binaries resolve their own dir, derive the repo root, then source the lib:

```bash
BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$BIN_DIR/.." && pwd)"
source "$REPO_ROOT/lib/config-lib.sh"
```

### Naming Conventions

| Type              | Convention         | Examples                                      |
|-------------------|--------------------|-----------------------------------------------|
| Shell scripts     | kebab-case / no ext in bin/ | `bin/claude-dockerized`, `run-simple.sh` |
| Hook scripts      | kebab-case         | `hooks/claude-guard-bash.sh`                  |
| Functions         | snake_case         | `check_docker()`, `build_image()`             |
| Constants         | UPPER_SNAKE        | `IMAGE_NAME`, `REPO_ROOT`, `CONFIG_DIR`       |
| Generated-home vars | CCODE_*          | `CCODE_HOME`, `CCODE_INSTALL_DIR`             |
| Wrapper env flags | CLAUDE_DOCKERIZED_* | `CLAUDE_DOCKERIZED_POLICY`, `CLAUDE_DOCKERIZED_WORKDIR` |
| Local variables   | lower_snake        | `project_dir`, `container_name`               |
| Global arrays     | UPPER_SNAKE        | `CUSTOM_MOUNTS=()`, `DOCKER_MOUNT_ARGS=()`   |
| Booleans          | UPPER_SNAKE=false  | `SSH_AGENT_SUPPORT=false` |
| Docker images     | kebab-case:tag     | `claude-dockerized:latest`                    |
| Container names   | kebab-case-suffix  | `claude-myproject-abc123`                     |

### Variable Handling

- **Always quote variables:** `"$variable"` not `$variable`
- **Command substitution:** `$()` not backticks
- **Declare and assign separately:** `local dir_name; dir_name=$(...)` (SC2155)
- **Absolute paths:** `BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"` + `REPO_ROOT="$(cd "$BIN_DIR/.." && pwd)"`
- **Defaults with `:=`:** `CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/claude-dockerized}"`
- **Color defaults in modules:** `: "${RED:='\033[0;31m'}"` (avoid overwriting caller-defined values)
- **Use arrays for Docker args:** Never build docker args as strings — use arrays and `"${array[@]}"`

### Color Output / Logging

Use the helpers from `lib/ui-lib.sh` (sourced through `lib/config-lib.sh`);
never hard-code ANSI escapes or `echo -e`:

```bash
print_info "..."     # stdout
print_success "..."  # stdout
print_warning "..."  # stderr
print_error "..."    # stderr
```

`config_info`/`config_success`/`config_warning`/`config_error` are the same
helpers under library names. Color is decided per stream (TTY only),
`NO_COLOR`, `TERM=dumb` and `--no-color` disable it, `CLICOLOR_FORCE=1`
forces it; symbols fall back to ASCII outside UTF-8 locales. Help texts
always print `claude-dockerized`, never `$0`.

### Error Handling

- Check prerequisites before operations (e.g., `check_docker`, `check_image` before Docker commands)
- Validate project directory exists before `cd`: `if [ ! -d "$dir" ]; then print_error ...; exit 1; fi`
- Print explicit error with `print_error()` then `exit 1`
- Suppress expected failures: `2>/dev/null || true`
- Graceful fallback in parsers: `load_config || return 0`
- Wrap `docker run` in error-handling: `if ! docker run ...; then print_error ...; exit 1; fi`
- Always use `read -r` to prevent backslash interpretation (SC2162)
- Validate env var names from config: `[[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]`
- Validate model names: letters, digits, `.`, `-`, `_` only (`case` glob `*[!A-Za-z0-9._-]*` in `load_config` and the wizard)

### Shared Logic (lib/mounts-lib.sh, lib/layer-lib.sh, lib/agent-lib.sh, lib/lsp-lib.sh)

All volume mount logic lives in `lib/mounts-lib.sh` to eliminate duplication (the security layer in `lib/layer-lib.sh`, agent forwarding in `lib/agent-lib.sh`, LSP installs in `lib/lsp-lib.sh`):
- `CCODE_HOME` (`~/.config/claude-dockerized/home`) — self-contained Claude Code state root mirroring the container home; all mounts source from here, never from host XDG dirs
- `build_standard_volume_args "$project_dir" [include_docker_socket]` — populates `VOLUME_ARGS` array with fine-grained mounts (managed policy dir `$CCODE_HOME/etc/claude-code` at `/etc/claude-code` read-only; the generated `~/.claude` read-write as a directory so `settings.json` saves never hit EBUSY, with `hooks-guard/` and `CLAUDE.md` overlaid read-only; `.claude.json`, sessions read-write; skills always read-only; plugins/agents/commands, `.local/bin` read-write, or read-only under `setting.hardening=strict`, which also overlays the project's `.git` hooks/config read-only; never the host `~/.claude`)
- `build_common_docker_args` — populates `DOCKER_COMMON_ARGS` array (--rm, --network host, `--user <host uid>:<host gid>`, `--group-add coder`, `--cap-drop=ALL`, `--security-opt no-new-privileges:true`, TERM, `CLAUDE_DOCKERIZED_POLICY`)
- `ensure_claude_dirs` — creates required host directories, seeds the state tree (credentials placeholder `0600`, `.claude.json`) and installs the versioned security layer (`ensure_claude_dockerized_config`: native hooks + `policies/*.json` with their `policies/VERSION` marker, `managed-settings.json` rendered from `config/managed-settings.json` by `write_managed_settings` (hooks, deny/ask, `DISABLE_AUTOUPDATER=1`, pinned policy mode, sandbox off) + writable preference-only `settings.json` seeded from `config/user-settings.default.json` by `ensure_user_settings` (legacy copies or `disableAllHooks` migrated by `lib/migrate-settings.js`), `hooks-guard/policy-mode`, `CLAUDE.md`, optional `.lsp.json`)
- `validate_mount_spec` / `sensitive_host_path_reason` / `canonical_host_path` — the single validator for custom mounts, the wizard and the project dir (canonical paths, `ro|rw`, refused host dirs such as credential stores in `$HOME`, `/root`, `/run`, container runtime sockets, and refused targets). `normalize_container_path` / `container_path_reason` resolve `.`/`..` in the container path and refuse system directories and the managed layer; `validate_project_dir` applies them to the project's own mount point (`~/usr` must not become `/usr`)
- `append_hardening_args` — opt-in `standard`/`strict` runtime flags (`setting.hardening`)
- `check_image "$IMAGE_NAME"` — validates Docker image exists
- `sanitize_container_name "$name"` — strips invalid Docker container name characters
- `generate_random_suffix` — produces random hex for unique container names
- `ensure_gpg_mirror` / `resolve_gpg_agent_socket` / `resolve_gpg_agent_extra_socket` — mirror the host's public GnuPG material into `$CCODE_HOME/.gnupg` (adding `no-autostart` to the mirrored `gpg.conf`) and locate the gpg-agent socket, preferring the restricted `S.gpg-agent.extra`; `build_mount_args`/`build_env_args` mount the mirror plus socket and set `GNUPGHOME` when `setting.gpg_agent_support=true` (private keys never shared)
- `ensure_lsp_formatters` / `write_lsp_json` — install LSP/formatter binaries into `$CCODE_HOME/.local/bin` (never system-wide) and generate `.lsp.json` from `setting.lsp_servers` when `setting.lsp=true`

### Main Entry Point Pattern

```bash
main() {
    local command="${1:-run}"
    shift || true
    case "$command" in
        run)    check_docker; check_config; run_claude "$@" ;;   # check_docker per command:
        build)  check_docker; build_image "$@" ;;                # config, version, doctor, update...
        config) show_config "$@" ;;                              # work without a daemon
        clean)  check_docker; clean_image ;;
        help|--help|-h) show_help ;;
        *)      print_error "Unknown command: $command"; show_help; exit 1 ;;
    esac
}
main "$@"
```

### Config File Format

INI-style (`key.name=value`), parsed with `while IFS='=' read -r key value` loops:
```ini
setting.ssh_agent_support=true
setting.gpg_agent_support=false
setting.docker_socket=false
setting.security_policy=balanced
setting.memory=4g
setting.cpus=2
setting.env_file=~/.config/claude-dockerized/env
setting.model=sonnet
setting.cleanup_days=7
setting.lsp=false
setting.lsp_servers=ts,python
setting.formatters=false
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
```

Removed settings (`websearch_provider`, `theme`) warn and are ignored. Secrets only travel via `setting.env_file` (refused when group/other-readable: `chmod 600`) (dotenv file under `~/.config/claude-dockerized/`,
`docker --env-file`, never mounted). The old `env.*` host passthrough was removed.

### Dockerfile Conventions

- Base image: `debian:trixie-slim` (pinned, not `latest`)
- Set `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` so RUN pipelines fail fast
- Parameterize tool versions via `ARG`: `ARG NVM_VERSION=v0.40.8`, `ARG CLAUDE_CODE_VERSION=2.1.296`, `ARG CLAUDE_BUILD_TIME=0` (cache-bust only for `update`)
- Install Claude Code only via the native installer (`curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}"`); never via npm (no official npm support)
- Do NOT bake LSP servers or formatters into the image; they live in the generated home (`ensure_lsp_formatters`)
- Clean apt cache in same RUN layer: `&& rm -rf /var/lib/apt/lists/*`
- Install Docker CLI only (`docker-ce-cli`), never the daemon
- No sudo: neither a sudoers entry nor the `sudo` binary (the agent must never gain root; the container starts as the host user via `--user`, `--cap-drop=ALL` and `no-new-privileges`, Docker access via `--group-add`)
- System packages as root; dev tools (NVM, uv) as non-root `coder` user
- Non-root user: `useradd -m -s /bin/bash -u 1000 coder`
- Create NVM default symlink for PATH: `ln -sf $(dirname $(which node)) $NVM_DIR/default`
- System git identity (`user.name Claude`, `safe.directory *`) via `git config --system`
- Use official installers from trusted sources

### Security Rules

- The security policy lives in the **managed** scope (`/etc/claude-code/managed-settings.json`, read-only, highest precedence); the user `settings.json` holds preferences only and stays writable (`/model`, `/config`, `/permissions`). Managed files (`/etc/claude-code/`, `hooks-guard/`, `CLAUDE.md`) are **read-only** mounts; user state (settings, credentials, plugins, sessions, `.local/bin`) read-write by default. The wrapper's `$CONFIG_DIR` is never mounted. The host `~/.claude` and `~/.mcp-auth` are never mounted; the MCP OAuth store is `$CCODE_HOME/.mcp-auth` (read-write, `0700`, also under strict). No host CLI directory is mounted (T-02)
- Guard hooks fail closed (exit 2 on anything they cannot evaluate), use a trusted tool path (`hook-path` / image default, never the inherited PATH) and read the mode from `hooks-guard/policy-mode` (`check_security_layer` verifies it matches `setting.security_policy`). They run under `#!/bin/bash -p` (no `$BASH_ENV`/`$ENV`) and unset startup/preload variables before spawning tools; the managed policy pins the preload variable empty. The tests execute the hook scripts directly, like Claude Code does, so the shebang is covered. The remote-flow override applies only to a single plain command (no chaining, expansion, redirect or upload). See `docs/security/YELLOW.md` before changing them
- `CLAUDE_DOCKERIZED_TEST_HOOKS=1` (with `CLAUDE_DOCKERIZED_TRUST_YES=1` for key pinning) is a test-only seam read from the host shell; the same opt-in gates `test_seam` for the gpg overrides. Never document it as a user feature
- Changes to persistent paths are reported after each `run` (`lib/integrity-lib.sh`, `setting.integrity_check`); stricter prevention is opt-in (`setting.hardening`) — defaults never change behavior silently
- Auto-updates always disabled via `env.DISABLE_AUTOUPDATER=1` in the managed policy; upgrades happen only through `claude-dockerized update` (signed release tag verified against locally pinned keys, preview, fast-forward, rebuild with pinned `CLAUDE_CODE_VERSION`; `rollback` undoes it)
- **Never commit:** `.env`, `.credentials.json`, `*.pem`, `*.key`, credentials
- Docker socket is **opt-in** (`setting.docker_socket`, default `false`): mount the host socket only on request, no privileged mode, grant the socket GID via `--group-add` (no root step). It is root-equivalent on the host.
- SSH agent forwarding is **opt-in** (`setting.ssh_agent_support`, default `false`): forwards only `SSH_AUTH_SOCK` and mounts `~/.ssh/config`/`known_hosts` read-only; private keys are never mounted and a custom mount of `~/.ssh` is refused
- GnuPG agent forwarding is **opt-in** (`setting.gpg_agent_support`, default `false`): mirrors only public material, prefers the restricted `S.gpg-agent.extra` socket, and sets `no-autostart`; private keys are never copied
- Security policy is configurable (`setting.security_policy`, default `balanced`: `strict` | `balanced` | `none`, with `off` accepted as an alias for `none`) and passed to the hooks as `CLAUDE_DOCKERIZED_POLICY`. Remote flows (git SSH, remote MCP, registries) stay allowed in all modes
- `hooks/claude-guard-*.sh` (+ `guard-eval.js`) is the guard source of truth; bump `CLAUDE_DOCKERIZED_GUARD_VERSION` when changing its behavior so installs refresh (previous copy backed up to `.bak`)
- Prefer `policies/allow-patterns.json` or a policy mode over editing the vendored `policies/*.json`
- In `balanced` mode the guard drops broad, whole-string false positives via the excluded-ID list in `hooks/guard-eval.js`; `strict` keeps them all; `none` keeps only the built-in backstops
- File-tool writes are confined to the project directory and `/tmp/claude` (the advertised scratch dir) by the file hook; the Claude sandbox is explicitly off (no bubblewrap in the image; the container is the boundary)
- `disableBypassPermissionsMode: disable` is always set in the managed settings; never set `disableAllHooks`
- Run as non-root `coder` inside container; the wrapper maps the host user with `--user <host uid>:<host gid>` so no root process runs
- Use `--rm` for automatic container cleanup; `--network host` for simplicity
- Custom user mounts default to read-only
- Only pass environment variables explicitly listed in config (plus non-secret terminal/agent state)
- Container names sanitized to prevent injection via directory names
- LSP/formatters are **opt-in** (`setting.lsp`, `setting.formatters`, default `false`): binaries install into `$CCODE_HOME/.local/bin` (never system-wide); `.lsp.json` is generated from `setting.lsp_servers`

## Volume Mounts Reference

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `$PROJECT_DIR` | `$PROJECT_DIR` (with `$HOME` stripped) | rw | Project files |
| `~/.config/claude-dockerized/home/etc/claude-code/` | `/etc/claude-code/` | **read-only** | Managed policy `managed-settings.json` (highest precedence): hooks, deny/ask, `DISABLE_AUTOUPDATER`, pinned policy mode, sandbox off. Rendered from `config/managed-settings.json` |
| `~/.config/claude-dockerized/home/.claude/` | `/home/coder/.claude/` | rw | Generated Claude state as a directory (a single-file bind would make settings saves fail with EBUSY); `settings.json` holds writable preferences seeded from `config/user-settings.default.json` (`/model`, `/config`, or `config claude edit`) |
| `~/.config/claude-dockerized/home/.claude/hooks-guard/` | `/home/coder/.claude/hooks-guard/` | **read-only** | Native `PreToolUse` hooks + policy data |
| `~/.config/claude-dockerized/home/.claude/CLAUDE.md` | `/home/coder/.claude/CLAUDE.md` | **read-only** | Managed session rules |
| `~/.config/claude-dockerized/home/.claude/.credentials.json` | `/home/coder/.claude/.credentials.json` | rw (`0600`) | Login (`claude auth login`), persists across rebuilds |
| `~/.config/claude-dockerized/home/.claude/plugins/` `agents/` `commands/` | same under `/home/coder/.claude/` | rw | User plugins, agents, commands |
| `~/.config/claude-dockerized/home/.claude/skills/` | `/home/coder/.claude/skills/` | **read-only** | User skills, managed from the host (T-05) |
| `~/.config/claude-dockerized/home/.claude/.lsp.json` | `/home/coder/.claude/.lsp.json` | rw | LSP config (generated when `setting.lsp=true`) |
| `~/.config/claude-dockerized/home/.claude.json` | `/home/coder/.claude.json` | rw | MCP user-scope state |
| `~/.config/claude-dockerized/home/.local/bin/` | `/home/coder/.local/bin/` | rw | LSP/formatter binaries (generated home) |
| `~/.config/claude-dockerized/home/.local/share/claude/` | `/home/coder/.local/share/claude/` | rw | Sessions, transcripts |
| `~/.config/claude-dockerized/home/.local/state/claude/` | `/home/coder/.local/state/claude/` | rw | History, locks |
| `~/.config/claude-dockerized/home/.cache/claude/` | `/home/coder/.cache/claude/` | rw | Caches |
| `~/.config/claude-dockerized/home/.mcp-auth/` | `/home/coder/.mcp-auth/` | rw (`0700`) | OAuth tokens of `mcp-remote` proxy servers (native Claude MCP OAuth lives in `.credentials.json`); read-write under strict too; the host `~/.mcp-auth` is never mounted |
| `~/.agents/` | `/home/coder/.agents/` | ro | Agent-compatible skills (skills/<name>/SKILL.md) |
| `~/.config/claude-dockerized/home/.gnupg/` | `/home/coder/.gnupg/` | rw (opt-in) | Mirrored **public** GnuPG material (pubring/trustdb/gpg.conf) + agent socket, only when `setting.gpg_agent_support=true`; `private-keys-v1.d/` is never copied |
| `/var/run/docker.sock` | `/var/run/docker.sock` | rw (opt-in) | Docker socket, only when `setting.docker_socket=true` |

The wrapper's own directory (`~/.config/claude-dockerized/`, i.e. `$CONFIG_DIR`) is **never** mounted. Its `CLAUDE.md`, hooks and policies are sourced from there and mirrored into the generated home; `managed-settings.json` is rendered from `config/managed-settings.json` and the wrapper config.
