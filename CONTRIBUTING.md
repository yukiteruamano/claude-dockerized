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
shellcheck -x -S warning bin/* lib/*.sh install.sh run-simple.sh completions/*.sh hooks/*.sh tests/*.sh tests/lib/*.sh
# …or without a local install:
uvx --from shellcheck-py shellcheck -x -S warning bin/* lib/*.sh install.sh completions/*.sh hooks/*.sh tests/*.sh
cat lib/config-lib.sh | docker run --rm -i koalaman/shellcheck:stable -s bash -x -S warning -

# 3. Dockerfile
cat Dockerfile | docker run --rm -i hadolint/hadolint:latest hadolint -

# 4. All test suites (Node.js 22+; no Docker needed)
bash tests/run-all.sh             # guard, bypass corpus, wrapper, mounts, config, update, CLI
bash tests/run-all.sh --verbose   # …and list every documented known gap
bash tests/run-all.sh --integration  # + container runtime checks (needs Docker)
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

Read [docs/security/YELLOW.md](docs/security/YELLOW.md) first: it holds the
non-negotiable rules for the guard, the wrapper and the supply chain, the
PR checklist and the release process. New attacks follow its "Adding an
attack" workflow ([RED](docs/security/RED.md) / [BLUE](docs/security/BLUE.md)).

- **`hooks/claude-guard-bash.sh` + `hooks/claude-guard-file.sh` are the source
  of truth.** They are copied into `~/.config/claude-dockerized/hooks/` by
  `lib/config-lib.sh`; when you change their behavior, bump
  `CLAUDE_DOCKERIZED_GUARD_VERSION` so existing installs are refreshed (their
  previous copy is backed up to `.bak`).
- **`policies/*.json` are vendored verbatim** (see `policies/README.md` for
  provenance). To change behavior for local use, prefer the policy mode
  (`strict` / `balanced` / `none`) or `policies/allow-patterns.json` over
  editing the vendored files.
- Add a case for every new deny/allow behavior — both that the dangerous
  thing is blocked and that normal development (including remote flows) is
  not. Command/path idioms go in `tests/claude-guard.test.mjs`; bypass
  attempts go in `tests/fixtures/guard-corpus.json` (data only, tagged with
  the threat id they exercise).
- **Known gaps.** A weakness that is documented but not fixed yet is recorded
  as `known_gap` (corpus / `.mjs` suites) or `gap <threat> …` (Bash suites).
  It is reported as XFAIL; when a fix makes it pass, the suite goes red until
  the marker is removed, so a fix can never silently regress later.
- A hook blocks only with **exit 2**; the tests treat any other non-zero exit
  as a crash (Claude Code runs the tool anyway), never as a deny.

## Docs

Update `README.md` (and `SECURITY.md` where relevant) for user-visible
changes. The wrapper config lives at `~/.config/claude-dockerized/config`.
