# Changelog

Releases are signed annotated tags (`docs/security/YELLOW.md#releases`).

## Unreleased

### Security

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
