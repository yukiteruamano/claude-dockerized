# Contributing

Thanks for helping improve `claude-dockerized`. This project is pure Bash
plus two small hook scripts, one Node.js policy evaluator and vendored JSON
policy data.

## Before you start

```bash
./install.sh          # installs bin/ on PATH, creates ~/.config/claude-dockerized + security layer
claude-dockerized build
```

## Checks (run before opening a PR)

CI runs all of these; you can run them locally:

```bash
# 1. Syntax
bash -n bin/claude-dockerized install.sh run-simple.sh
for f in lib/*.sh completions/*.sh hooks/*.sh; do bash -n "$f"; done
node --check hooks/guard-eval.js

# 2. ShellCheck (any of these)
shellcheck -x -S warning bin/* lib/*.sh install.sh run-simple.sh completions/*.sh hooks/*.sh
# …or without a local install:
cat lib/config-lib.sh | docker run --rm -i koalaman/shellcheck:stable -s bash -x -S warning -

# 3. Dockerfile
cat Dockerfile | docker run --rm -i hadolint/hadolint:latest hadolint -

# 4. Security policy regression tests (Node.js 22+) and wrapper contract test
node --check hooks/guard-eval.js lib/migrate-settings.js
node tests/claude-guard.test.mjs
bash tests/wrapper-args.test.sh
```

## Style

- Follow the conventions in [AGENTS.md](AGENTS.md) (kebab-case scripts,
  snake_case functions, UPPER_SNAKE constants, quoted variables, `$()`, arrays
  for Docker arguments).
- Every executable script starts with `#!/bin/bash` + `set -e`;
  `lib/config-lib.sh` and `lib/install-lib.sh` are sourced libraries and must **not** use `set -e`.
- The binary is `bin/claude-dockerized` (no extension), reached via
  `<install>/bin` on PATH. Nothing is ever placed in `~/.local/bin`
  (no symlink, stub or copy).
- Keep security the priority: never weaken a deny rule without a documented
  reason and a test.

## Security layer changes

- **`hooks/claude-guard-bash.sh` + `hooks/claude-guard-file.sh` are the source
  of truth.** They are copied into `~/.config/claude-dockerized/hooks/` by
  `lib/config-lib.sh`; when you change their behavior, bump
  `CLAUDE_DOCKERIZED_GUARD_VERSION` so existing installs are refreshed (their
  previous copy is backed up to `.bak`).
- **`policies/*.json` are vendored verbatim** (see `policies/README.md` for
  provenance). To change behavior for local use, prefer the policy mode
  (`strict` / `balanced` / `none`) or `policies/allow-patterns.json` over
  editing the vendored files.
- Add a case to `tests/claude-guard.test.mjs` for every new deny/allow
  behavior — both that the dangerous thing is blocked and that normal
  development (including remote flows) is not.

## Docs

Update `README.md` (and `SECURITY.md` where relevant) for user-visible
changes. The wrapper config lives at `~/.config/claude-dockerized/config`.
