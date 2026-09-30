# Red team — attack playbook

> Offensive view of the sandbox: how an agent that has turned hostile
> (prompt injection, malicious dependency) would try to break out, persist or
> steal secrets, and **which test reproduces each attempt**. Controls and
> response live in [BLUE.md](BLUE.md); ids refer to
> [THREAT-MODEL.md](THREAT-MODEL.md).

## Rules of engagement

- Only against your own installation, in a **disposable project** with no
  real secrets; use a separate `CONFIG_DIR`/`HOME` (the test suites do this
  automatically).
- Attack strings are data, kept in `tests/fixtures/guard-corpus.json` and the
  suites; this document describes classes of attack, not ready-to-paste
  payloads.
- Findings go through the private advisory process in
  [SECURITY.md](../../SECURITY.md#reporting-a-vulnerability) before anything
  public.

## Running the exercise

```bash
bash tests/run-all.sh --verbose        # every attack below, no Docker needed
bash tests/run-all.sh --integration    # + attacks that need the real image
node tests/guard-bypass-corpus.test.mjs   # just the guard corpus
```

A case that documents a weakness which still reproduces is marked
`known_gap` (corpus) or `gap T-xx …` (Bash suites) and reports **XFAIL**;
when the fix lands it turns red until the marker is removed. A new attack is
added the same way: first as a failing case, then fixed (see
[YELLOW.md](YELLOW.md#adding-an-attack)).

## Kill chain

| Phase | Goal of the attacker | Threats |
|-------|----------------------|---------|
| Recon | learn user, capabilities, mounts, env names, policy mode | — (always possible; `doctor` shows the same) |
| Credential access | read provider keys, OAuth stores, SSH/GPG material | T-10, T-19, T-25, T-26 |
| Defense evasion | switch off or blind the guard | T-03, T-04, T-08, T-09, T-11, T-16, T-30 |
| Privilege escalation | root inside the container | T-21, T-22, T-27, T-28 |
| Persistence | survive the session | T-02, T-04, T-05 |
| Escape to host | run code as the host user | T-01, T-02, T-06, T-07, T-20 |
| Supply chain | reach users through updates or images | T-12, T-13, T-14, T-24, T-29 |
| Host-side races | abuse the wrapper on a shared host | T-15, T-17, T-18 |
| Impact | exhaust the machine | T-23 |

## Attack catalog

Each entry: **attack class** · precondition · impact · reproduced by.
Result on the current code is in the matrix of THREAT-MODEL.md.

### Defense evasion

- **T-03 — Relax the policy from the project.** Write
  `.claude/settings.local.json` (or an `env` override of the policy variable)
  so the next session runs with fewer rules or without hooks. *Pre:* write
  access to the project (always). *Impact:* every soft control. *Tests:*
  `guard-tool-coverage` (policy lives in the managed scope),
  `guard-failure-modes` ("policy-mode file wins over env"), corpus
  `write-project-settings-local` (blocked in strict).
- **T-04 — Hijack the guard's helpers.** Plant `jq`/`node`/`claude` in the
  persistent, writable `~/.local/bin`, which used to come first on PATH, so
  the hook parses nothing or the evaluator always answers "allow". *Impact:*
  guard off for the session and every later one. *Tests:*
  `guard-failure-modes` ("fake jq/node on PATH"), `entrypoint`,
  integration (planted `claude` never resolves).
- **T-08 — Shadow the backstops with an allowed token.** Append a template
  name or a `*.pub` path to a forbidden command so an allow rule
  short-circuits the evaluation; copy a private key to a `*.pub` name.
  *Tests:* corpus `allow-token-*`, `pub-suffix-*`.
- **T-09 — Use a tool the guard does not see.** `NotebookEdit` / `MultiEdit`
  writes outside the project, a `Grep` with a `glob` that targets secret
  files. *Tests:* corpus `notebook-*`, `multiedit-*`, `grep-glob-*`;
  `guard-tool-coverage`.
- **T-11 — Make the guard crash open.** Malformed payloads, removing its
  parsers, corrupting or emptying the policy data, an unknown mode: any
  non-2 exit used to let the tool run. *Tests:* `guard-failure-modes`,
  CI job without jq/python3.
- **T-16 — Smuggle `disableAllHooks` through a settings merge.** *Tests:*
  `merge-settings`, `wrapper-args`.
- **T-30 — Rely on a sandbox that is not there.** `sandbox.enabled` without
  bubblewrap silently ran unsandboxed. *Tests:* `guard-tool-coverage`.

### Credential access

- **T-10 — Read credential stores the rules forgot** (OAuth store, git/pypi
  credentials, netrc, docker/gh/kube/gcloud configs) via shell or file tools.
  *Tests:* corpus `*-credentials-*`, `netrc-*`, `docker-config-*`, `gh-hosts-*`.
- **T-26 — Read `.env`, keys, `auth.json`, including through symlinks**
  planted in the project. *Tests:* `claude-guard` read cases.
- **T-19 — Dump the environment** (`env`, interpreter dumps, `/proc/*/environ`).
  *Tests:* `claude-guard` env-dump cases. Residual: provider keys are in the
  environment by design.
- **T-25 — Query cloud metadata** (literal, decimal, hex, octal, IPv6 forms).
  *Tests:* `claude-guard` metadata cases.

### Privilege escalation

- **T-28 — Gain capabilities or setuid root inside the container.** *Tests:*
  `wrapper-dryrun` (flags on every entry point), integration (`CapEff=0`,
  `NoNewPrivs=1`, arbitrary UID).
- **T-21 — Abuse a leftover setuid binary.** Neutralized by
  `no_new_privileges`; removable at build. *Tests:* integration inventory, CI
  hardened image.
- **T-22 — Tamper with the image at runtime** (writable rootfs, group-writable
  toolchain) to influence the rest of the session. *Tests:* `hardening`
  (strict read-only rootfs), integration strict profile.
- **T-27 — Get the wrapper started as root.** *Tests:* `wrapper-dryrun`.

### Persistence and escape

- **T-01 — Make the host run code:** add a git hook or a `core.fsmonitor` /
  `core.hooksPath` / filter entry to the project's `.git`, which the host's
  git (or the shell prompt) runs later. *Tests:* `integrity` (reported),
  `hardening` (read-only overlays in strict), corpus `write-git-hook` (strict).
- **T-02 — Replace a host CLI** kept in a read-write mount (`~/.composio`).
  *Tests:* `integrity`, `hardening`.
- **T-05 — Persist into every later session:** add an MCP stdio server, a
  plugin, skill, agent or command in the generated home. *Tests:* `integrity`,
  `hardening`.
- **T-07 — Get more of the host mounted:** a config mount written in a
  non-canonical form (`..`, `//`, symlink) that slips past the deny list, the
  whole home, the wrapper's config dir, the docker socket, a propagation mode,
  or a target that shadows the managed read-only mounts. *Tests:* `mounts`.
- **T-06 — Reach host loopback services** through the shared network
  namespace. *Tests:* `wrapper-dryrun` (default documented), `hardening`
  (bridge in strict).
- **T-20 — Use the Docker socket** (opt-in) to start a privileged container.
  *Tests:* `wrapper-dryrun` (never mounted by default), `mounts` (cannot be
  smuggled in as a custom mount).

### Supply chain

- **T-12 — Ship code through the updater:** push to the upstream branch, add
  an unsigned or impostor-signed tag, rewrite an existing tag, or change the
  `origin` remote. *Tests:* `self-update`.
- **T-13 — Break the install with a bad update** and no way back. *Tests:*
  `self-update` (rollback point, `:prev`, `rollback`).
- **T-14 — Run install scripts on the host** through the LSP/formatter
  installer. *Tests:* `lsp-install`.
- **T-24 — Move an image input:** re-point a base image tag, a mutable
  installer tag or an unpinned tool. *Tests:* `supply-chain`.
- **T-29 — Hijack a CI action tag** (as happened with `trivy-action`,
  CVE-2026-33634). *Tests:* `supply-chain` (every `uses:` pinned by SHA).

### Host-side and impact

- **T-15 — Edit the installed guard without changing its version marker.**
  *Tests:* `wrapper-args` content integrity.
- **T-17 — Race the wrapper's temp files** on a shared host. *Tests:*
  `config-parse` private temp dir.
- **T-18 — Put the env file where the session can read and rewrite it.**
  *Tests:* `mounts`.
- **T-23 — Exhaust the host** (fork bomb, memory). *Tests:* `hardening`
  (pids limit in standard/strict).

## Tabletop scenarios

1. *A README in a cloned repo tells the agent to "register the project's
   helper MCP server".* Expected: the server entry is written (allowed in the
   default profile), the session-end report lists `.claude.json#mcpServers`,
   the audit log records it; with `hardening=strict` plugins/skills are
   read-only and the change is still reported.
2. *A dependency's install script copies a shim to `~/.local/bin/git`.*
   Expected: the shim never shadows the image's git (PATH order), the report
   lists the planted file, the guard keeps using its trusted path.
3. *An attacker pushes a tag `v9.9.9` signed with their own key.* Expected:
   `update` refuses ("not signed by a trusted release key"), nothing changes,
   `update --check` exits 100 and says "NOT verified".
4. *The agent tries to widen its own mounts* by editing the wrapper config.
   Expected: impossible from the container (`$CONFIG_DIR` is never mounted);
   a host-side config with `~/.ssh` or the socket is refused at startup.
