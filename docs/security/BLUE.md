# Blue team — controls, detection and response

> Defensive view: every control, where it lives in the code, how it is
> verified, what is detected when prevention is not on, and how to respond.
> Attacks are in [RED.md](RED.md); ids refer to
> [THREAT-MODEL.md](THREAT-MODEL.md).

## Defense in depth

The design does not rely on any single layer. From hardest to softest:

| # | Layer | Nature | Survives a hostile agent? |
|---|-------|--------|---------------------------|
| 1 | Container runtime: host UID, no capabilities, no new privileges, seccomp | kernel-enforced | yes |
| 2 | Mount plan: what is visible, what is read-only | kernel-enforced | yes |
| 3 | Managed policy (`/etc/claude-code/managed-settings.json`, read-only) | enforced by Claude Code | yes (outside the agent's reach) |
| 4 | Guard hooks (`PreToolUse`, exit 2) | heuristic over tool input | partially (text matching) |
| 5 | Session integrity report | detection after the fact | yes (runs on the host) |
| 6 | Human review | judgment | — |

Layers 1–3 and 5 do not depend on recognizing a malicious command; layer 4
reduces noise and blocks the obvious.

## Controls by layer

### Image (`Dockerfile`)

| Control | Threat | Verified by |
|---------|--------|-------------|
| Non-root `coder`, no privilege-escalation binary, no sudoers | T-28 | integration, `wrapper-args` |
| Base image by digest; NVM by commit; Node, uv, Claude by exact version (asserted); Docker apt key by fingerprint; optional Claude sha256 (TOFU) | T-24 | `supply-chain` |
| Root-owned node copy for the guard (`/usr/local/lib/claude-dockerized/bin`) | T-04 | integration |
| Opt-in `STRIP_SETUID=1`, `DOCKER_CLI=0` | T-21, T-20 | CI hardened image |

### Runtime (`lib/config-lib.sh`: `build_common_docker_args`, `build_standard_volume_args`)

| Control | Threat | Verified by |
|---------|--------|-------------|
| `--user <host uid>:<gid>`, `--cap-drop=ALL`, `no-new-privileges`, `--rm` on every entry point; wrapper refuses root | T-27, T-28 | `wrapper-dryrun`, integration |
| Managed policy, hooks, `CLAUDE.md` read-only; `$CONFIG_DIR` never mounted; `~/.ssh`/`~/.gnupg` private material never mounted | T-03, T-15 | `wrapper-args`, `wrapper-dryrun` |
| Mount validation: canonical paths, `ro`/`rw` only, sensitive host dirs, docker socket, managed/system targets | T-07 | `mounts` |
| Env file only under `$CONFIG_DIR`, never in the mounted home | T-18 | `mounts` |
| Read-write binds only from the generated home and the project: no host CLI or token directory (the MCP OAuth store is `$CCODE_HOME/.mcp-auth`, `0700`) | T-02 | `hardening`, `wrapper-args` |
| Docker socket off by default | T-20 | `wrapper-dryrun` |
| `~/.local/bin` last on PATH | T-04 | `entrypoint`, integration |
| User skills (`~/.claude/skills/`) read-only in every profile, plus `Edit(~/.claude/skills/**)` deny | T-05 | `hardening`, corpus `write-user-skill` |
| `setting.hardening=standard`: `--init`, `--pids-limit`, private IPC | T-23 | `hardening` |
| `setting.hardening=strict`: read-only rootfs + tmpfs; read-only plugins/agents/commands/`~/.local/bin`; read-only `.git` hooks/config overlays; bridge network | T-01, T-05, T-06, T-22 | `hardening`, integration |

### Policy (`config/managed-settings.json`, rendered by `write_managed_settings`)

| Control | Threat | Verified by |
|---------|--------|-------------|
| Mounted at the managed-settings path (highest precedence; `env` per variable wins; managed hooks cannot be disabled from lower scopes) | T-03 | `guard-tool-coverage`, `wrapper-args` |
| `DISABLE_AUTOUPDATER=1`, pinned `CLAUDE_DOCKERIZED_POLICY`, `disableBypassPermissionsMode`, deny/ask rules | T-03, T-12 | `guard-tool-coverage` |
| Hook matcher covers Read/Edit/MultiEdit/Write/NotebookEdit/Glob/Grep | T-09 | `guard-tool-coverage` |
| Sandbox explicitly off (no bubblewrap; the container is the boundary) | T-30 | `guard-tool-coverage` |
| User settings are writable preferences only; `config sync` drops `disableAllHooks` (and `--check` flags it) | T-16 | `migrate-settings`, `wrapper-args` |

### Guard (`hooks/`)

| Control | Threat | Verified by |
|---------|--------|-------------|
| Trusted tool path (`./hook-path` or the image default), never the inherited PATH | T-04 | `guard-failure-modes` |
| Fail closed: exit 2 on empty/unparseable payloads, missing parser, missing/corrupt/empty/uncompilable policy, crashed evaluator, unknown mode (→ strict) | T-11 | `guard-failure-modes`, CI job without jq/python3 |
| Mode pinned in `./policy-mode` (read-only), env only a fallback | T-03 | `guard-failure-modes` |
| Allow rules only relax vendored rules; public-key exemption per token | T-08 | corpus |
| Secret paths incl. credential stores, case-insensitive for files; symlink targets resolved | T-10, T-26 | corpus, `claude-guard` |
| Env dumps, `/proc/*/environ`, metadata IP forms, docker escapes, destructive root targets | T-19, T-25 | `claude-guard` |
| Strict mode protects `.git` hooks/config and project Claude settings | T-01, T-03 | corpus |

### Host-side layer (`sync`, `lib/integrity-lib.sh`, `lib/update-lib.sh`)

| Control | Threat | Verified by |
|---------|--------|-------------|
| `config sync --check` compares hooks, evaluator and deny sets byte for byte (repo → install → mirror) and the managed policy with its template; `sync` restores (with `.bak`) | T-15 | `wrapper-args` |
| Private 0700 `TMPDIR`; atomic settings writes | T-17 | `config-parse` |
| Session integrity report + JSONL audit log (default on) | T-01, T-05 | `integrity`, `wrapper-dryrun` |
| Verified updates (pinned keys, origin pin, preview, confirmation, fast-forward, re-exec), rollback | T-12, T-13 | `self-update` |
| LSP/formatters pinned, installed in a throwaway container with `--ignore-scripts` | T-14 | `lsp-install` |
| CI actions pinned by SHA, Dependabot, release tags verified | T-29, T-12 | `supply-chain`, `release-verify.yml` |

## Detection

| Signal | Where | What it means |
|--------|-------|---------------|
| "Session integrity: these persistent paths changed…" | terminal after `run` | the session touched something that runs on the host or in later sessions |
| `~/.config/claude-dockerized/audit/sessions.jsonl` | host, 0600 | one record per session with changes (time, project, paths) |
| `claude-dockerized doctor` / `doctor --json` | host + container | layer drift, image/pin mismatch, missing release key, last integrity record, socket mounted, root filesystem mode |
| `claude-dockerized config sync --check` | host | any byte of the enforced layer differing from the repo |
| `claude-dockerized update --check` | host | 100 = release available; "NOT verified" = not signed by a pinned key |
| Guard messages `Blocked by …` | session | what the guard refused (exit 2) |

Useful triage commands:

```bash
tail -n 5 ~/.config/claude-dockerized/audit/sessions.jsonl
git -C <project> diff -- .git/config; ls -la <project>/.git/hooks
ls -la ~/.config/claude-dockerized/home/.local/bin
claude-dockerized doctor --json | jq '.host[] | select(.status != "pass")'
```

## Incident response

**1. A session changed a persistent path you did not expect.**
1. Do not run git in the project from the host yet (hooks/config could run).
   Inspect with `ls -la .git/hooks` and `cat .git/config` instead.
2. Remove what you did not add (`git config --unset …`, delete the hook,
   delete the file in `~/.config/claude-dockerized/home/...`).
3. Review the session transcript for the prompt that led there (prompt
   injection source: repo file, issue, web page, MCP result).
4. Consider `setting.hardening=strict` for untrusted projects.

**2. Suspected secret exposure.**
1. Rotate the provider key in the env file and the Claude login
   (`claude-dockerized auth`); revoke MCP OAuth tokens (`mcp logout`).
2. If agent forwarding was on, review the host agent's recent use (GPG
   signatures, SSH logins) and remove keys you do not need forwarded.
3. Check the audit log and transcripts for the time window.

**3. The security layer drifted or was tampered with.**
1. `claude-dockerized config sync --check` to list the differences.
2. `claude-dockerized config sync` restores the repo copies (the edited ones
   are kept as `*.bak` for inspection).
3. If the repo checkout itself is suspect, `git -C <install> status` and
   `git -C <install> log --show-signature -3`.

**4. A bad or suspicious update.**
1. `claude-dockerized rollback` (checkout + `:prev` image), then
   `claude-dockerized config sync`.
2. Verify what was applied: `git log --show-signature <old>..<new>`.
3. If a tag was rewritten upstream, `update` refuses it and says so: report
   it to the maintainers.

## Known limits

See the residual-risk section of THREAT-MODEL.md: the guard is a heuristic,
the project is read-write, provider credentials are visible to the session,
forwarded agents are signing oracles, `--network host` is the default and the
release key / Claude binary hash are trusted on first use.
