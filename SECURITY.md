# Security

`claude-dockerized` sandboxes an autonomous coding agent (Claude Code, native
binary). It reduces blast radius; it is **not** a hard boundary against a
determined attacker with a kernel or container-runtime exploit. The agent is
treated as untrusted code execution inside the container.

## Documents

| Document | Contents |
|----------|----------|
| [docs/security/THREAT-MODEL.md](docs/security/THREAT-MODEL.md) | scope, assets, adversaries, trust boundaries, STRIDE, the threat matrix (T-01…T-30) with status and tests, residual risk |
| [docs/security/RED.md](docs/security/RED.md) | attack playbook: kill chain, attack catalog per threat, how to run the exercise, tabletop scenarios |
| [docs/security/BLUE.md](docs/security/BLUE.md) | controls by layer with their code location and test, detection signals, incident response |
| [docs/security/YELLOW.md](docs/security/YELLOW.md) | secure-development rules, adding an attack, PR checklist, signed releases, CI; Purple/Orange/Green appendix |

## What is enforced (summary)

- **Rootless runtime.** The container runs as the host UID/GID with
  `--cap-drop=ALL` and `no-new-privileges` on every entry point; the image
  has no privilege-escalation binary; the wrapper refuses to run as root.
- **Managed policy out of the agent's reach.** Hooks, deny/ask rules and the
  policy mode live in `/etc/claude-code/managed-settings.json` (read-only,
  highest precedence), so project settings cannot relax them; auto-updates
  are disabled; the guard hooks and policy data are read-only mounts,
  verified byte for byte on the host.
- **Fail-closed guard.** `PreToolUse` hooks for Bash and every file tool
  block with exit 2 on anything they cannot evaluate, use a trusted tool
  path, and cover secret paths, credential stores, environment dumps, cloud
  metadata, docker escapes and destructive root targets. Remote development
  flows stay allowed in every mode.
- **Mount plan.** Only the project, the generated home and explicit,
  validated mounts are visible; `~/.ssh` / `~/.gnupg` private material, the
  wrapper's config dir and the Docker socket (unless opted in) never are.
- **Detection by default.** Changes to paths that run on the host or in later
  sessions (git hooks/config, `~/.local/bin`, plugins, skills, MCP servers,
  `.composio`) are reported after every session and logged.
- **Opt-in prevention.** `setting.hardening=standard|strict` (pids limit,
  read-only root filesystem, read-only persistent paths and `.git` overlays,
  bridge network), `setting.image_strip_setuid`, `setting.image_docker_cli`.
- **Verified updates.** Signed release tags checked against locally pinned
  keys, preview and confirmation, fast-forward only, rollback. Image inputs
  and CI actions are pinned by digest/commit/exact version.

## Known limitations

- The guard matches command text: it is a heuristic. The container and the
  mount plan are the boundary.
- The project is mounted read-write: review what the agent changes,
  including code the host runs later (tests, scripts, git hooks).
- Provider credentials from the env file are visible to the session; the
  Claude login (`.credentials.json`, 0600) is read-write so it persists.
- `--network host` is the default (host loopback services are reachable);
  use `setting.network=bridge` or `setting.hardening=strict`.
- Forwarded SSH/GnuPG agents (opt-in) are signing oracles while a session
  runs; private keys are never mounted.
- The Docker socket (opt-in) is root-equivalent on the host.
- In the default profile the root filesystem is writable and persistent
  paths are read-write (changes are detected, not prevented).
- The release key and the Claude binary hash are trusted on first use:
  check the key fingerprint through a second channel.
- Prompt injection is only partly mitigated. Review the agent's actions.

## Reporting a vulnerability

Open a private security advisory on the repository, or email the
maintainers. Include a reproduction (command, `DRY_RUN=true` output,
`claude-dockerized doctor --json`, configuration) and the expected vs.
observed behavior. Do not open a public issue for exploitable findings
before a fix is available.
