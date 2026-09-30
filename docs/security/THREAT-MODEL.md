# Threat model — `claude-dockerized`

> Part of the security documentation set: [SECURITY.md](../../SECURITY.md)
> (index) · **THREAT-MODEL** (this file) · [RED](RED.md) (attack playbook) ·
> [BLUE](BLUE.md) (controls, detection, response) · [YELLOW](YELLOW.md)
> (secure development). Every threat id below is exercised by at least one
> test (`tests/threat-matrix.test.sh` enforces it).

## 1. Scope and assumptions

`claude-dockerized` runs an autonomous coding agent (Claude Code) inside a
Docker container on a developer workstation. The agent executes shell
commands, edits files and fetches URLs, and it can be steered by untrusted
content (prompt injection in a repo, an issue, a web page, an MCP tool
result). **The agent is treated as untrusted code execution inside the
container.**

Assumptions:

- The host OS, the Docker daemon and the user's account are trusted and
  patched. Rootless Docker or userns-remap further reduce a daemon escape.
- The container runtime enforces `--user`, `--cap-drop=ALL`,
  `no-new-privileges` and the default seccomp/AppArmor profiles.
- The user reviews what the agent changes in the project (it is read-write
  by design).
- Remote development flows (git over SSH, registries, remote MCP, APIs) must
  keep working in every policy mode: the design blocks destruction,
  exfiltration of secrets and escapes, not "talking to the network".

Out of scope: a malicious host user, kernel/runtime 0-days (container escape
through the kernel), a compromised Anthropic API, and data the user
deliberately mounts or puts in the env file.

## 2. Assets

| Asset | Where | Why it matters |
|-------|-------|----------------|
| Host account and files | outside the container | code execution as the user = full compromise |
| Provider credentials | `setting.env_file` → container env; `.credentials.json` | account takeover, billing |
| Signing oracles | forwarded SSH / GnuPG agents (opt-in) | impersonation (signed commits, SSH auth) |
| MCP OAuth tokens | `~/.mcp-auth` | access to connected services |
| Security layer | managed policy, hooks, policies, wrapper code | disabling it removes every soft control |
| Project source | the mounted project | integrity of the user's work, supply chain of their users |
| Future sessions | generated home (`~/.local/bin`, plugins, skills, MCP config) | persistence across sessions and projects |

## 3. Adversaries

| Actor | Capability |
|-------|------------|
| A1 Prompt-injected agent | arbitrary commands and file edits inside the container, within the guard |
| A2 Malicious dependency / tool | runs as the agent (npm/pip install scripts, a planted MCP server) |
| A3 Compromised upstream | pushes code or tags to the wrapper repo, or to an image input (base image, installers) |
| A4 Network attacker (MITM) | tampers with unauthenticated downloads |
| A5 Other local user (multi-user host) | races predictable paths in shared `/tmp` |

## 4. Trust boundaries

```
 upstream (A3) ──fetch──▶ [B4 update/build] ──▶ host: wrapper code, image
                                                   │
 host user ─────────────────────────────────── [B1 wrapper → docker run]
                                                   │  --user uid:gid, cap-drop=ALL,
                                                   │  no-new-privileges, managed ro mounts
                                                   ▼
                      ┌──────────── container (A1, A2) ────────────┐
                      │ Claude Code ──tool call──▶ [B2 guard hooks] │
                      │        │                                   │
                      │        ▼ writes                            │
                      │ project (rw) · generated home (rw/ro)       │
                      └──────────────┬─────────────────────────────┘
                                     ▼
            [B3 persistence: host git runs .git hooks; next session runs
             ~/.local/bin, plugins, MCP servers]
```

- **B1 host → container**: what the wrapper grants (user, capabilities,
  mounts, env, network).
- **B2 agent → tool**: what the guard lets a tool call do.
- **B3 container → host / future**: what outlives the session and is later
  executed by someone more trusted.
- **B4 upstream → host**: what an update or a build brings in.

## 5. STRIDE per boundary

| Boundary | S | T | R | I | D | E |
|----------|---|---|---|---|---|---|
| B1 | — | project settings relax the policy (T-03) | — | env secrets (T-19), metadata IP (T-25) | fork bomb / memory (T-23) | root in container (T-28), docker socket (T-20), setuid (T-21), writable rootfs (T-22), bad mounts (T-07), wrapper as root (T-27) |
| B2 | — | tamper with the guard's helpers (T-04) or policy data (T-11) | — | secret reads (T-10, T-26), allowlist shadowing (T-08), unrouted tools (T-09) | — | guard fail-open (T-11) |
| B3 | — | host-executed git config/hooks (T-01), host CLI (T-02) | integrity log (BLUE) | — | — | persistence into later sessions (T-05) |
| B4 | impostor release (T-12) | rewritten tags, unpinned inputs (T-24), CI actions (T-29), LSP installs (T-14) | release-verify workflow | — | bad update without rollback (T-13) | — |
| Host-side wrapper | — | layer drift/tampering (T-15), merge keeps `disableAllHooks` (T-16), env file in a mounted dir (T-18) | — | — | — | shared temp race (T-17) |
| Settings | false assurance from an inert sandbox (T-30) | — | — | — | — | — |

Network exposure through `--network host` (T-06) spans B1 (information
disclosure of loopback services) and is accepted by default.

## 6. Threat matrix

Status legend: **mitigated** (control in place, test green) · **detected**
(reported, not prevented) · **accepted** (documented residual risk) ·
**opt-in** (prevention available behind a setting).

| Id | Threat | Status | Evidence (tests) |
|----|--------|--------|------------------|
| T-01 | Host code execution via the project's `.git` (`hooks/`, `config`: `core.fsmonitor`, `core.hooksPath`, filters) and tool configs run by the host | detected (default) · prevented (strict policy / strict hardening) | integrity `git hook`, `git config`; hardening `.git overlays`; corpus `write-git-hook` (strict) |
| T-02 | Host binary replacement through the read-write `~/.composio` mount | detected (default) · prevented (strict hardening) | integrity `~/.composio`; hardening `~/.composio read-only` |
| T-03 | Managed policy override from the project: `.claude/settings.local.json`, or `env` relaxing `CLAUDE_DOCKERIZED_POLICY` | mitigated | managed policy at `/etc/claude-code/managed-settings.json` (tool-coverage, wrapper-args, dryrun); failure-modes `policy-mode file wins over env`; corpus `write-project-settings-local` (strict) |
| T-04 | Helper hijack: writable `~/.local/bin` first on PATH shadows `jq` / `node` / `claude` used by the guard | mitigated | failure-modes `fake jq/node on PATH`; entrypoint PATH order; integration planted `~/.local/bin/claude`, root-owned guard node |
| T-05 | Cross-session persistence via read-write `.claude.json` (MCP stdio), plugins, skills, agents, commands, `.lsp.json` | detected (default) · prevented (strict hardening, except `.claude.json`) | integrity `MCP server`, `skill`, `~/.local/bin`; hardening read-only plugins/skills/agents/commands |
| T-06 | Host network exposure (`--network host`: loopback services, abstract sockets) | accepted (default) · opt-in bridge (strict hardening) | dryrun `default network is host`; hardening `strict: bridge network` |
| T-07 | Custom mount / project-dir validation bypass (non-canonical paths, symlinks, `$HOME`, `/`, config dirs, docker socket, arbitrary modes, shadowed managed targets) | mitigated | `tests/mounts.test.sh` (canonical paths, sensitive dirs, modes, managed targets, project dir) |
| T-08 | Guard allowlist token (`.env.example`, `*.pub`) short-circuits every backstop | mitigated | corpus `allow-token-*`, `pub-suffix-*`, `authorized-keys-*` |
| T-09 | Guard coverage gaps: `NotebookEdit` / `MultiEdit` not routed, `notebook_path` / `glob` fields ignored | mitigated | corpus `notebook-*`, `multiedit-*`, `grep-glob-*`; tool-coverage matcher |
| T-10 | Credential stores missing from the deny rules (`.credentials.json`, `.git-credentials`, `.netrc`, docker/gh configs) | mitigated | corpus `*-credentials-*`, `netrc-*`, `docker-config-*`, `gh-hosts-*` |
| T-11 | Guard fails open: malformed payload, missing jq/node, corrupt or empty policy data, unknown mode | mitigated | `tests/guard-failure-modes.test.mjs`; corpus `empty-policy-mode-file-*`; CI job without jq/python3 |
| T-12 | Unverified self-update: upstream compromise reaches host code, hooks and image | mitigated (after you pin a release key) | `tests/self-update.test.sh` (signed / impostor / unsigned / rewritten tags, origin pin, preview, confirmation); `install.sh` contract in supply-chain; release-verify workflow |
| T-13 | No rollback point for a bad update or failed rebuild | mitigated | self-update rollback point, `:prev` image, `rollback`; failed rebuild prints recovery |
| T-14 | Unpinned LSP/formatter installs executed on the host | mitigated | `tests/lsp-install.test.sh` (pinned, in-container, --ignore-scripts, no host npm/uv) |
| T-15 | Security-layer tampering undetected (`sync --check` compares version markers only) | mitigated | wrapper-args content-integrity (edited hook keeping its marker, tampered mirror, tampered managed policy) |
| T-16 | Settings merge keeps security-disabling keys (`disableAllHooks`) | mitigated | merge-settings `disableAllHooks is dropped`; wrapper-args merge |
| T-17 | Shared, predictable host temp dir (`/tmp/claude`) — race on multi-user hosts | mitigated | config-parse private temp dir (0700, symlink refused) |
| T-18 | Env file placed inside the mounted generated home | mitigated | mounts `env file inside the mounted generated home` |
| T-19 | Secrets visible through the process environment | accepted (mitigated by guard) | claude-guard env-dump cases |
| T-20 | Docker socket is root-equivalent on the host | accepted (opt-in, off by default) | dryrun `docker socket not mounted by default` |
| T-21 | Residual setuid/setgid binaries in the image | accepted (neutralized by no_new_privs) · opt-in `image_strip_setuid` | integration setuid inventory; CI hardened image build |
| T-22 | Writable root filesystem and group-writable toolchain | accepted (default) · opt-in read-only rootfs (strict hardening) | hardening `strict: read-only rootfs`; integration strict profile |
| T-23 | Resource exhaustion (no pids/memory limits by default) | accepted (default) · opt-in pids limit (standard/strict) | hardening `standard: pids limit` |
| T-24 | Image supply chain (base by tag, piped installers, unpinned tools) | mitigated (TOFU for the Claude binary sha256) | `tests/supply-chain.test.sh` (base digest, NVM commit, Node/uv/Claude versions, apt key fingerprint) |
| T-25 | Cloud metadata / link-local exfiltration | mitigated | claude-guard metadata cases |
| T-26 | Secret file reads through tools (`.env`, keys, `auth.json`, symlink escapes) | mitigated | claude-guard read cases |
| T-27 | Wrapper started as root on the host | mitigated | dryrun `root is refused` |
| T-28 | Privilege escalation inside the container (capabilities, setuid) | mitigated | dryrun rootless flags; integration caps/no_new_privs |
| T-29 | CI supply chain: mutable action tags (cf. CVE-2026-33634) | mitigated | `.github/workflows/ci.yml` SHA pins |
| T-30 | Inert `sandbox.enabled` gives false assurance (no bubblewrap in the image) | mitigated | tool-coverage `managed policy keeps the inert sandbox off` |

## 7. Residual risk (accepted)

- **The guard is a heuristic, the container is the boundary.** Pattern
  matching over command text cannot be complete (quoting, encoding,
  interpreters). Everything the container can reach, a determined agent can
  reach; the controls that do not depend on text matching are B1 (user,
  capabilities, mounts) and B3 detection.
- **The project is read-write.** The agent can change or delete anything in
  it, including code that runs later on the host (tests, build scripts). Git
  hooks/config are detected by default and read-only under
  `setting.hardening=strict`; everything else needs human review.
- **Provider credentials are visible to the session** (T-19): they configure
  the CLI. Keep unrelated secrets out of the env file.
- **Forwarded agents are signing oracles** while a session runs (opt-in).
- **`--network host` by default** (T-06): loopback services on the host are
  reachable. Use `setting.network=bridge` or `setting.hardening=strict`.
- **First-use trust.** The release key and the Claude binary hash are
  trusted on first use; verify the key fingerprint out of band.
