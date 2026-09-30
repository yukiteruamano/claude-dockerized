# Threat model — `claude-dockerized`

> Catalog of threat ids referenced by the test suites (`tests/`) and the
> Red / Blue / Yellow documents. Each id maps to at least one test or a
> documented known gap (`known_gap` / `gap T-xx …`), which reports as XFAIL
> until the fix lands and turns red afterwards until the marker is dropped.
> Status legend: **gap** = reproduces today, **mitigated** = test green,
> **accepted** = documented residual risk.

| Id | Threat | Status | Evidence (tests) |
|----|--------|--------|------------------|
| T-01 | Host code execution via the project's `.git` (`hooks/`, `config`: `core.fsmonitor`, `core.hooksPath`, filters) and tool configs run by the host | gap | corpus `write-git-hook`, `edit-git-config` |
| T-02 | Host binary replacement through the read-write `~/.composio` mount | gap | — (Phase 3 integrity check) |
| T-03 | Managed policy override from the project: `.claude/settings.local.json`, or `env` relaxing `CLAUDE_DOCKERIZED_POLICY` | gap | corpus `write-project-settings-local`; failure-modes `policy-mode file wins over env` |
| T-04 | Helper hijack: writable `~/.local/bin` first on PATH shadows `jq` / `node` / `claude` used by the guard | gap | failure-modes `fake jq/node on PATH` |
| T-05 | Cross-session persistence via read-write `.claude.json` (MCP stdio), plugins, skills, agents, commands, `.lsp.json` | gap | — (Phase 3 integrity check) |
| T-06 | Host network exposure (`--network host`: loopback services, abstract sockets) | accepted (default) | dryrun `default network is host` |
| T-07 | Custom mount / project-dir validation bypass (non-canonical paths, symlinks, `$HOME`, `/`, config dirs, docker socket, arbitrary modes, shadowed managed targets) | gap | `tests/mounts.test.sh` |
| T-08 | Guard allowlist token (`.env.example`, `*.pub`) short-circuits every backstop | gap | corpus `allow-token-*` |
| T-09 | Guard coverage gaps: `NotebookEdit` / `MultiEdit` not routed, `notebook_path` / `glob` fields ignored | gap | corpus `notebook-*`, `multiedit-*`, `grep-glob-*`; tool-coverage |
| T-10 | Credential stores missing from the deny rules (`.credentials.json`, `.git-credentials`, `.netrc`, docker/gh configs) | gap | corpus `*-credentials-*`, `netrc-*`, `docker-config-*`, `gh-hosts-*` |
| T-11 | Guard fails open: malformed payload, missing jq/node, corrupt or empty policy data, unknown mode | gap | `tests/guard-failure-modes.test.mjs` |
| T-12 | Unverified self-update: upstream compromise reaches host code, hooks and image | gap | self-update `unsigned upstream commit` |
| T-13 | No rollback point for a bad update or failed rebuild | gap | self-update `previous image is tagged` |
| T-14 | Unpinned LSP/formatter installs executed on the host | gap | — (Phase 4) |
| T-15 | Security-layer tampering undetected (`sync --check` compares version markers only) | gap | — (Phase 2 manifest) |
| T-16 | Settings merge keeps security-disabling keys (`disableAllHooks`) | gap | merge-settings `disableAllHooks is dropped` |
| T-17 | Shared, predictable host temp dir (`/tmp/claude`) — race on multi-user hosts | gap | — (Phase 2) |
| T-18 | Env file placed inside the mounted generated home | gap | mounts `env file inside the mounted generated home` |
| T-19 | Secrets visible through the process environment | accepted (mitigated by guard) | claude-guard env-dump cases |
| T-20 | Docker socket is root-equivalent on the host | accepted (opt-in, off by default) | dryrun `docker socket not mounted by default` |
| T-21 | Residual setuid/setgid binaries in the image | accepted (neutralized by no_new_privs) | integration setuid inventory |
| T-22 | Writable root filesystem and group-writable toolchain | accepted (default) | dryrun `no read-only rootfs by default` |
| T-23 | Resource exhaustion (no pids/memory limits by default) | accepted (default) | dryrun `no pids limit by default` |
| T-24 | Image supply chain (base by tag, piped installers, unpinned tools) | gap | — (Phase 4) |
| T-25 | Cloud metadata / link-local exfiltration | mitigated | claude-guard metadata cases |
| T-26 | Secret file reads through tools (`.env`, keys, `auth.json`, symlink escapes) | mitigated | claude-guard read cases |
| T-27 | Wrapper started as root on the host | mitigated | dryrun `root is refused` |
| T-28 | Privilege escalation inside the container (capabilities, setuid) | mitigated | dryrun rootless flags; integration caps/no_new_privs |
| T-29 | CI supply chain: mutable action tags (cf. CVE-2026-33634) | mitigated | `.github/workflows/ci.yml` SHA pins |
| T-30 | Inert `sandbox.enabled` gives false assurance (no bubblewrap in the image) | gap | — (Phase 2) |

Non-security contract gaps use `UX-xx` / `CFG-xx` labels in the same
XFAIL mechanism (tracked in the CLI/UX phase).
