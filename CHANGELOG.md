# Changelog

Releases are signed annotated tags (`docs/security/YELLOW.md#releases`).

## Unreleased

### Security

- **Guard v7** (`CLAUDE_DOCKERIZED_GUARD_VERSION=7`, all modes):
  - Secret names spelled with shell globs (`.en?`, `.en[v]`, `id_e*`, `.cred*`, `server.p?m`) are denied when a read/copy verb is present; a globbed word needs two literal characters, so `*`, `*.*`, `src/*.ts` stay allowed.
  - The backstops also see the command with its quotes removed, so split quotes (`.e""nv`, `id_ed"25519"`) no longer hide a secret name.
  - Bare code identifiers containing `_key_` (e.g. `grep -n profile_overlay_key_ok`) no longer trip the key-material rule; `server_key`, `deploy-key` and reading a `*_key_*` file stay denied.
  - Brace expansion and variable concatenation remain known gaps in `balanced`/`none` (corpus `brace-expansion-env`, `variable-concat-env`).

## 0.4.6

### Changed

- Documentation only: no code or behavior change.
  - `README.md` re-synced with the profile layout and the per-session agent state: accurate state tree (`profiles/<name>/{config,env,home/}` plus `profiles.map`, `trust`, `state`, `audit/`, `backups/`, `agent-relay/<pid>-<kind>/`), the relay paths, the current command list, working troubleshooting steps (no more `docker rm -f claude-dockerized`) and a complete File Reference.
  - Long run-on bullets became sub-sections and one-idea bullets; the examples are headings now; one mounts row used a `|` inside inline code and broke the table, which is fixed.
  - `SECURITY.md`, `docs/security/THREAT-MODEL.md` and `AGENTS.md` follow the matrix to T-35 and state the limits of concurrent sessions (shared profile home, one pinentry at a time).
  - Quick Start pins `CCODE_REF=v0.4.5` instead of the stale `v1.2.0`.

### Fixed

- The `0.4.4` heading was missing from this file, so its entry (LSP/formatter installs) appeared under `0.4.5`.

## 0.4.5

### Fixed

- Concurrent sessions (`gpg_agent_support` / `ssh_agent_support`) no longer interfere with each other:
  - The mirrored **public** GnuPG material is now per session (`profiles/<name>/home/.gnupg-sessions/<pid>`, `0700`, deleted when the session ends). A shared mirror let a second session delete the `keyboxd` database and the `S.gpg-agent` symlink of a running one, and the container's own keyboxd vanished with the first session. Mirrors left by a crash (or by a previous boot, which reuses PIDs) are purged by the next run; the pre-0.4.5 shared `home/.gnupg` is removed unless `GNUPGHOME` points at it.
  - Keyring files are copied through a temporary file and a rename, so a host `keyboxd` writing `pubring.kbx` while a session starts can no longer leave a torn keyring in the container.
  - Relay sockets are one directory per session **and** kind (`agent-relay/<pid>-gnupg`, `<pid>-ssh`) under the renamed `SOCKET_RELAY_DIR` (`GPG_RELAY_DIR` is still honored, its default moved from `gnupg-relay` to `agent-relay`).
  - `ssh_agent_support` relays `SSH_AUTH_SOCK` through the same mechanism when the socket lives on the per-user `/run` tmpfs (which Docker cannot bind), mounting it at `/home/coder/.ssh-agent/ssh` and pointing `SSH_AUTH_SOCK` there. Sessions keep sharing the one host agent.
  - An enabled GnuPG forwarding with no host `GNUPGHOME` no longer mounts an empty `~/.gnupg`.
- Documented the multi-session model (per-session agent state, the profile home still shared, one pinentry at a time) and added the threat it isolates (T-35).

## 0.4.4

### Fixed

- Opt-in LSP/formatter installs (`setting.lsp`, `setting.formatters`) now persist in the profile instead of reinstalling on every `run`:
  - The install script run in the throwaway container used `local` outside a function, which aborted it after `npm install` and before the links were created, so every run reported a failed install and retried (`bash: line 7: local: can only be used in a function`).
  - `tsserver` is no longer expected: `typescript@7` does not ship that bin, so the verification could never pass.
  - When any npm tool is missing, the whole wanted npm set is installed in one command (`npm install --no-save` prunes the rest of the prefix, which made ts, pyright and prettier wipe each other in a reinstall loop).

## 0.4.3

Supersedes `0.4.2`, whose tag was cut from a commit that does not descend from `master` (an install on `master` could not fast-forward to it). Same fixes, now on top of `master`.

### Fixed

- `update`:
  - A rebuild that fails after the code was fast-forwarded is now finished by the next `update` (it used to answer "Already up to date" and leave the old image); `update --check` reports the pending rebuild.
  - `rollback` restores `:prev` only when the last update rebuilt the image (a `--no-build` update used to be rolled back onto an older image), and an image-only rebuild (`--claude-version` with the code up to date) gets its own rollback point instead of moving the code back.
  - The rollback point is committed only after the fast-forward succeeds, so a refused merge keeps the previous one.
  - A release tag must carry its own name in the signed payload: a validly signed tag republished under another name is refused.
  - A checkout ahead of upstream is "up to date" (not "diverged"), and a newer release that does not descend from the checkout is reported as a divergence instead of being ignored.
  - A failed security-layer refresh after an update is reported (exit 1) instead of "Update complete"; a worktree checkout (`.git` as a file) can update; a pin that differs from the Dockerfile default is called out.

## 0.4.1

### Changed

- Claude Code is pinned to `2.1.311` (was `2.1.296`; `stable` channel).
- Image tools: Node.js `24.22.2`, uv `0.13.7`, pnpm `12.16.1`; `debian:trixie-slim` digest refreshed.
- Opt-in LSP/formatter pins: ruff `0.17.3`, prettier `3.9.10`, typescript-language-server `6.0.3`, gopls `v0.24.0`.
- `WRAPPER_VERSION` is `0.4.1`.

## Unreleased

### Security

- **Guard v6** (`CLAUDE_DOCKERIZED_GUARD_VERSION=6`): fewer false positives in `balanced`, measured on a corpus mined from real sessions (`tests/fixtures/guard-fp-corpus.tsv`: 14 of 23 benign commands were denied, now 0; payload shapes stay denied, 2,500 fuzzed payloads per variant at 100%). `strict` is unchanged.
  - The payload check measures a path segment by segment, so an upper-case directory (`/WORK/…`), a long slug, a timestamped migration name or a path with a digest inside no longer reads as a base64 token; a token is a payload only when 32 or more of its characters are not explained by a path part or an id.
  - Hex ids of md5, sha224 and `0x` EVM address / transaction hash lengths join the digest lengths, and bech32 addresses (`bc1…`, `tb1…`, `ltc1…`) are recognised. `xxd` counts as a decoder only with `-r`.
  - `base64-decode-exec-en-1`, `base64-decode-exec-ru-1` (any `decode` before a later `run` in a chained command) and `xxd-exfil` are dropped in `balanced`. In their place a narrow check denies a decoder (`base64 -d`, `b64decode`, `atob(`) whose output is evaluated on the same line (`eval`, `source`, `sh -c`, `bash -c`), reported as `base64-decode-exec-line`.
  - Known gap: a base64url payload split with hyphens still passes in both modes (listed as XFAIL in `tests/guard-eval.test.mjs`).
- **Guard v5** (`CLAUDE_DOCKERIZED_GUARD_VERSION=5`):
  - `balanced` no longer applies the vendored `base64-payload-1` / `base64-payload-2`, which denied any 40+ character run before or after `run`/`exec` (container ids, commit hashes, long paths or script names next to `npm run` / `docker exec`). In their place `hooks/guard-eval.js` checks, in balanced only, for a whole-word `run`/`exec` and a base64-looking token on the same line, before or after it (reported under the same rule ids). Not a payload: a path or script name made of words (lower-case, camelCase or PascalCase, digits allowed), a hex run of a digest length (40/64/96/128) unless a decoder such as `pack`, `fromhex`, `xxd`, `hex` or `Buffer` is on the line. Hex of any other length, and random letters, still count as a payload. `strict` keeps the vendored rules unchanged. The vendored `policies/*.json` are untouched.
- **Guard v4** (`CLAUDE_DOCKERIZED_GUARD_VERSION=4`; installs refresh on the next run, the previous copy is kept as `.bak`):
  - Both hooks run under `#!/bin/bash -p` and drop startup/preload variables, so settings `env` can no longer make them exit 0 early; the managed policy pins the preload variable empty.
  - The balanced/none remote-flow override applies only to a single plain command: chained, expanded, redirected or uploading commands are judged by the vendored rules.
  - Bash writes (redirects, `tee`, `cp`, `mv`, `rm`, ...) to `.git/hooks`, `.git/config`, project/user `settings*.json`, `~/.local/bin` and skills are denied in every mode; `rm -rf` of `~`, `$HOME`, `.` and `..` is denied.
  - File hook: writes below a symlink over a directory that does not exist yet are caught (`realpath -m`); exemptions (`*.pub`, `.env.example`, `authorized_keys`, `public-keys.d/`) apply to the final path component only; relative reads resolve against the project; recursive Grep/Glob roots over `$HOME`, `/` and credential stores are refused; `CLAUDE_DOCKERIZED_PROJECT_DIR` no longer widens the write roots; strict mode also protects `.mcp.json`, `.gitmodules`, `.claude/commands` and `.claude/agents`.
  - More secret names: `.envrc`, `.pgpass`, `.aws/`, `*.p12|pfx|jks`, shell history, `.claude.json`, `/proc/**/environ` (also via `task/` and `..`), `$IFS` obfuscation, upper-case `.PEM`/`.KEY`.
- The project's own container path is validated like a custom mount (`~/usr`, `~/etc`, `~/bin` ... are refused); mount targets are normalised before the shadowing check.
- Mount sources: credential stores in `$HOME` (`.aws`, `.kube`, `.docker`, `.claude`, `.netrc`, `.npmrc`, ...), `/root`, `/run`, `/proc`, `/sys`, `/dev`, `/etc` secrets and every container runtime socket are refused.
- An env file readable by group/others is refused (was a warning); `GPG_RELAY_DIR` overrides must be inside the config dir or named `gnupg-relay*`.
- The session integrity check also fingerprints the command-running keys of the user `settings.json`.
- `check_security_layer` verifies the pinned `policy-mode`.
- New default user settings (new installs only) no longer auto-allow `find`, `pnpm *`, `npm run *`, `make *`, `uv run *` or `git commit`.

### Changed

- `lib/config-lib.sh` (3.6k lines) is split into `config-lib`, `mounts-lib`, `layer-lib`, `agent-lib`, `lsp-lib` and `wizard-lib` (function bodies unchanged); the session-rules template moved to `config/session-rules.md`; `ensure_claude_dockerized_config` and `load_config` are composed of small functions; `run`/one-off commands share `build_session_args` and `run_docker_session`.
- `exec` requires the message before any option.
- `run-simple.sh` builds through the wrapper (pinned version and build args apply).
- `WRAPPER_VERSION` is `0.3.0`; a test keeps it from falling behind the latest tag.

### Tests

- 46 new guard-corpus cases, a mount/target/env-file/relay matrix in `tests/mounts.test.sh`, user-settings integrity cases, and `tests/commands.test.sh` (models, stats, debug, exec, uninstall, upgrade/rollback, refusals).
- The hook tests execute the scripts directly (shebang included); `tests/run-all.sh` lists self-skipped suites and `--no-skip` fails on them.
