# Security Model

`claude-dockerized` sandboxes an autonomous coding agent (Claude Code, native
binary). It reduces blast radius; it is **not** a hard security boundary
against a determined attacker. This document states what it does and does not
protect against.

## Threat model

The agent is untrusted code execution: it may run arbitrary shell commands,
edit files, and fetch URLs, and it may be steered by untrusted content (prompt
injection). The wrapper's job is to keep that activity inside a container with
the least access it needs to be useful — while keeping remote development
flows (git over SSH, remote MCP servers, registries, APIs) working in every
policy mode.

## What is enforced

| Control | How |
|---------|-----|
| Non-root execution | Image has no `sudo` (no binary, no sudoers); the wrapper starts the container with `--user <host uid>:<host gid>` and `--cap-drop=ALL`, so no root process runs at any point and `entrypoint.sh` performs no privilege changes |
| Project-only writes | Only the project directory and the generated home are mounted; a file hook denies edits whose absolute path is outside the project (resolving symlinks via `realpath`, so a link inside the project cannot be used to escape). Only the project and `/tmp/claude` are writable |
| Managed settings | `settings.json` is generated on the host (permissions `deny`/`ask`, `sandbox`, `disableBypassPermissionsMode: disable`, `DISABLE_AUTOUPDATER: 1`) and mounted **read-only** as a single file; a session cannot relax its own rules. `disableAllHooks` is detected by `doctor`/`sync --check` |
| Native hooks | Versioned `PreToolUse` hooks (`hooks/claude-guard-*.sh`, exit 2 blocks) evaluate the vendored policy sets in `strict`, `balanced` (default) or `none` modes, plus mode-independent backstops. Remote flows (git SSH, `https` registries/MCP) are allowed in all modes; only destruction, exfiltration, secrets and Docker escapes are blocked |
| No auto-updates | `env.DISABLE_AUTOUPDATER=1` is always set in the managed settings (verified by `claude doctor`); upgrades happen only through `claude-dockerized update` (image rebuild with a pinned `CLAUDE_CODE_VERSION`) |
| Secret reads | Managed `permissions.deny` rules plus the hooks refuse reads of `.env` (except `.env.example`), `*.pem`, `*.key`, `auth.json`, `credentials*`, `~/.npmrc`, `~/.mcp-auth/`, `~/.ssh/`, SSH keys (`id_rsa`, `id_eddsa`, `id_ecdsa`, `id_dsa`) and `private-keys-v1.d/` — both via file tools and from shell commands |
| GnuPG agent forwarding (opt-in) | `setting.gpg_agent_support=true` mirrors only the public keyring (`pubring.kbx` / `public-keys.d`) and forwards the host `gpg-agent` socket (preferring the restricted `S.gpg-agent.extra`), mounted at a dedicated path and exposed through a symlink in the mirrored keyring; the host agent is started on demand unless `setting.gpg_autostart_agent=false` (after a `gpg-connect-agent` liveness probe); the mirrored config keeps `use-keyboxd` and sets `no-autostart`, and the container starts keyboxd at boot; the full-control main socket is only used with `setting.gpg_allow_main_socket=true`; `private-keys-v1.d/` is never copied or mounted, and a custom mount of `~/.gnupg` is refused |
| SSH agent forwarding (opt-in) | `setting.ssh_agent_support=true` forwards only the host `SSH_AUTH_SOCK` and mounts `~/.ssh/config`/`known_hosts` read-only; private keys (`id_*`, `*.pem`, `*.key`) are never mounted, and a custom mount of `~/.ssh` is refused |
| Dangerous commands | Deny rules + hook backstops for `sudo`, `rm -rf /`, `mkfs`, `dd of=/dev/…`, `shutdown`/`reboot`; `git push` requires approval |
| Self-protection | Managed files are mounted **read-only** (fine-grained mounts, never `~/.claude` as a whole); the hooks and policies are mirrored into the generated home on the host by the wrapper, so a session cannot relax its own rules or add a persistent hook/MCP server. Credentials (`.credentials.json`, `0600`) live in a read-write mount |
| Policy patterns | The vendored policy pattern sets, evaluated by `hooks/guard-eval.js` with the same first-match semantics upstream uses (see `policies/README.md`) |
| LSP/formatters (opt-in) | `setting.lsp`/`setting.formatters` install binaries into the generated home (`~/.local/bin`) and generate `.lsp.json`; nothing is installed system-wide, so the image stays slim and rebuilds keep working |

## Known limitations

- **Docker socket is opt-in but root-equivalent.** With
  `setting.docker_socket=true` the container gets the host Docker socket, which
  allows mounting `/` and escaping to host root. It is **off by default**;
  enable it only for Docker-in-Docker / Testcontainers.
- **`--network host`.** The container shares the host network namespace by
  default, so it can reach host services and the internet without
  restrictions. Use `setting.network=bridge` for more isolation.
- **GnuPG agent forwarding is a signing oracle.** With
  `setting.gpg_agent_support=true` the container can ask the host `gpg-agent` to
  sign arbitrary data while it runs; it cannot read the private keys. Pinentry
  runs on the host agent. It is **off by default**; enable it only when you
  need signed commits/tags.
- **SSH agent forwarding is a signing oracle.** With
  `setting.ssh_agent_support=true` the container can authenticate/sign with the
  host agent while it runs; it cannot read the private keys. Destructive agent
  operations (`ssh-add -D/-d/-x/-X/-e`) and host-agent control
  (`gpgconf --kill/--reload`) are blocked, but anything the agent is authorised
  for can be used from the container. **Off by default.**
- **Agent sockets are bind-mounted, not created.** The SSH/GPG agent sockets are
  attached with `--mount type=bind`, so a stale or missing source fails instead
  of Docker creating a directory at the host socket path.
- **GPG needs a mirrored public keyring.** If no `pubring.kbx` /
  `public-keys.d/pubring.db` exists in the host `GNUPGHOME`, signed commits fail;
  the wrapper warns instead of failing silently, and `claude-dockerized doctor`
  reports it from inside the container.
- **`config sync` writes host state (by design).** Only `config sync --check` is
  side-effect free: plain `sync` creates missing directories, refreshes the
  versioned layer (backing up replaced files) and regenerates the managed
  settings. User files (`config`, env file, MCP state) are never modified.
- **GPG socket relay.** Many Docker setups cannot bind a socket under a per-user
  tmpfs (`/run/user/<uid>/gnupg/…`) — they create an empty directory instead. The
  wrapper relays the restricted `S.gpg-agent.extra` socket through a socket on a
  normal filesystem (`socat`, under the wrapper config dir) for the lifetime of
  the session. Install `socat`; without it GPG forwarding is skipped with a
  warning (`setting.gpg_relay=false` disables the relay).
- **No read-only root filesystem.** `--cap-drop=ALL` and
  `--security-opt no-new-privileges:true` are enabled, but the rootfs stays
  writable. Adding `--read-only` with tmpfs mounts is future hardening work.
- **Policy patterns are heuristics.** They can both miss traffic and (in
  `strict` mode) flag legitimate commands. `balanced` mode drops the most
  common false positives; `none` disables the vendored patterns while keeping
  the built-in backstops. Remote flows are explicitly allowed in all modes.
- **Project mount is read-write and shares the host filesystem.** The agent can
  modify (or delete) anything inside the mounted project directory.
- **Managed files are read-only.** `settings.json`, hooks and `CLAUDE.md` in
  the generated home are read-only mounts, so in-session changes to them do not
  persist; `claude mcp add/remove` and `claude plugin install/update/remove` do
  not work from the container — use the host (`config claude path` shows
  where). Auth/MCP-OAuth (`login`/`logout`) live in read-write mounts, so they
  keep working.
- **Credentials file is read-write.** `.credentials.json` (`0600`) is mounted
  read-write so login persists; the agent can read or alter its own login.
  Never commit or share it.
- **Environment variables in the container are visible to the agent.** Provider
  keys from the secrets file (e.g. `ANTHROPIC_API_KEY`) end up in the container
  environment and in `docker inspect` on the host. This is intentional (it is
  how the CLI is configured) but means a session can read its own provider
  credentials; keep unrelated host secrets out of the env file.
- **Secret reads are heuristic.** Reads of `.env` (except `.env.example`),
  `*.pem`, `*.key`, key-like file names (including bare `*key`), `auth.json`,
  `credentials*`, `~/.npmrc`, `~/.mcp-auth/`, `~/.ssh/`, `~/.gitconfig` and
  `~/.composio/` are denied via file tools and shell backstops; an obfuscated
  command could still reach data that is not mounted at all. The bare `*key`
  heuristic also blocks unrelated names ending in "key" (e.g. `monkey`
  is explicitly allowed; `mykey` is treated as a key file).
- **Inline secrets in managed settings abort the run.** Credentials in settings
  must use environment-variable substitution or `apiKeyHelper`; literal
  `apiKey`/`token`/`secret`/`password` values are rejected by the wrapper and
  reported by `doctor`. Keep the values in `setting.env_file` (never mounted,
  passed via `docker --env-file`).
- **Bare environment dumps are denied.** `env`, `printenv`, `set`, `export`,
  `declare` and `typeset` with no arguments (plus `export -p`, `declare -p`,
  `typeset -p`, `compgen -e`, `compgen -v`, `declare -x`, `typeset -x`) are
  blocked in every policy mode; scoped uses (`printenv PATH`,
  `env FOO=1 cmd`, `set -e`, `declare -A map`) stay allowed. Targeted reads of
  secret-like names (`printenv SECRET`, `printenv *_KEY`, `*_TOKEN`,
  `*_PASSWORD`, `*CREDENTIAL*`) are denied; `echo $VAR` expansion stays allowed
  by design (blocking it would break ordinary scripting).
- **Bulk interpreter dumps are denied, member access stays allowed.**
  `console.log(process.env)`, `print(os.environ)`, `puts ENV`, `print %ENV`,
  `print_r($_ENV)` and `Deno.env.toObject()` dumps are blocked in every mode;
  single-variable reads (`process.env.PATH`, `os.environ.get("X")`,
  `ENV["X"]`, `$ENV{X}`, `getenv("X")`) stay allowed. Staged copies
  (`x = {...process.env}` printed later) remain a documented residual.
- **Destructive root targets are denied.** `rm -rf /`, `rm -rf /*` and `rm`
  with `/..` traversals, `chmod 777 /|/*|traversal` and `chown /|traversal`,
  `mkfs`, `dd of=/dev/…` and `>/dev/sd*` are blocked in every mode.
  Project-scoped deletion (`rm -rf dist/*`, `rm -rf .`) stays allowed: the
  project mount is read-write by design.
- **Proc/metadata/docker-escape backstops are mode-independent.**
  Reads of `/proc/*/environ`, the cloud metadata IP (literal, decimal, hex and
  octal forms) and `docker -v /:/`, `--volume /:/` and `--mount …,source=/,…`
  mounts plus `docker --privileged` are blocked even with
  `setting.security_policy=none`. Named volumes and host subdirectories stay allowed.
- **Git exfiltration over key material is denied.** `show`/`cat-file` of
  `rev:path` key paths, `log -p`, non-`--stat` `diff`, `grep` and `archive`
  over `*.key`/`*.pem`/key-like names are blocked in every mode; `git log
  --oneline`, `git show HEAD:README.md` and `git diff --stat` stay allowed.
- **Renamed extractor binaries are denied (token-gated).** A local executable
  (`./k`, `/tmp/…`) with `ssh-keygen -y -f` or `openssl … -in/-text` flag
  shapes over a key-like target is blocked; the same flags over ordinary files
  stay allowed. Plain renamed readers without extraction flags remain a
  documented heuristic residual.
- **Write confinement depends on the hook.** Edits are confined by the file
  hook — including relative targets, which are resolved against the project
  directory; if the hook failed to load, writes fall back to the runtime
  default. The managed files are mounted read-only, so a session cannot relax
  the hooks.
- **Prompt injection is only partly mitigated.** Rules and hooks reduce the
  impact; they do not make the agent trustworthy. Review its actions.

## Reporting a vulnerability

Open a private security advisory on the repository, or email the maintainers.
Please include a reproduction (command, `DRY_RUN=true` output, and container
configuration) and the expected vs. observed behavior. Do not open a public
issue for exploitable findings before a fix is available.
