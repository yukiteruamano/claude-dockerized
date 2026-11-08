# Yellow team — building it securely

> Rules for everyone who changes `claude-dockerized` (humans and agents).
> They exist because each one was broken once; the id in brackets is the
> threat it protects (see [THREAT-MODEL.md](THREAT-MODEL.md)).

## Non-negotiable rules

### Guard hooks (`hooks/`)

- **Only exit 2 blocks.** Any other non-zero exit is a non-blocking error
  for Claude Code and the tool runs, and so does a hook that times out.
  Every failure path exits 2 with a `Blocked by …` message [T-11].
- **Fail closed.** Unparseable input, a missing parser, missing or broken
  policy data and unknown modes block. Never add a "best effort, allow on
  error" branch [T-11].
- **Never trust the inherited environment.** Tools come from the trusted
  path (`./hook-path` or the image default), the mode from `./policy-mode`;
  env vars are only fallbacks because project settings can inject them
  [T-03, T-04].
- **No early `exit 0`.** An allow match may relax one specific rule; it must
  never skip the remaining checks. Exemptions are per token, never for the
  whole command: `guard-eval.js` cuts the matched text out and the deny rules
  judge the rest; chained or substituted input (`$(…)`, backticks) gets no
  exemption. Profile allow rules that match the empty string or a known
  attack are refused (`lib/merge-allow-patterns.js`) [T-08, T-36].
- **Bounded time.** Claude Code runs the tool when a hook times out (30 s),
  so a slow regex is a fail-open. Commands above 64 KiB are refused, the
  policy engine runs under `timeout` (15 s, deny on expiry, `timeout`
  missing is a deny), and vendored rules with several `.*` use the
  backtracking-free form documented in `policies/README.md` [T-11].
- **Normalize like the shell.** Quotes and unquoted backslashes do not end a
  word (`.e\nv` is `.env`), globs can spell a name (`/proc/self/env*`), and
  Claude Code expands a leading `~` in file paths: check every spelling, never
  the raw string only [T-26].
- **Never widen the write roots.** `CLAUDE_PROJECT_DIR` must be an absolute
  project path (not `/`, the home or an ancestor, a tool or credential dir in
  the home, a system dir); otherwise only `/tmp/claude` is writable. Roots are
  arrays, never a delimited string [T-03].
- **`ask` is not `allow`.** The bash hook answers `git push` in any spelling
  (`git -C . push`, `command git push`, `/usr/bin/git push`) with the JSON
  `permissionDecision: "ask"` and exit 0, after every deny check passed,
  because the managed `Bash(git push *)` ask rule is prefix-based. An alias
  configured earlier (`git config alias.p push`) still evades it.
- **Dump denials are best effort.** Environment dumps (`env`, `printenv`,
  `ps e`, `os.environ`, `ENVIRON`, `/proc/*/environ`) are matched by their
  common spellings; a program can always print its environment in a way no
  pattern foresees. Keep secrets out of the session environment where
  possible instead of relying on these rules [T-19].
- **Every file-touching tool and field.** A new tool or input field goes
  into the matcher (`config/managed-settings.json`) and the parsers, with
  corpus cases [T-09].
- **Bump `CLAUDE_DOCKERIZED_GUARD_VERSION`** when behavior changes, so
  installs refresh (content is verified byte for byte anyway [T-15]).

### Wrapper (`bin/`, `lib/`)

- **Arrays for docker arguments**, never strings; quote every expansion.
- **Paths from config are canonicalized** (`canonical_host_path`) and
  checked with `sensitive_host_path_reason` / `validate_mount_spec` before
  they reach docker [T-07].
- **Nothing executable or secret in a read-write mount** without a
  detection or strict-mode story (`lib/integrity-lib.sh`,
  `setting.hardening`) [T-01, T-05]; read-write binds come only from the
  generated home and the project, never a host CLI or token dir [T-02].
- **Defaults do not change behavior silently.** New hardening is opt-in (a
  setting) plus detection by default; say so in the commit.
- **`set -e` traps:** a function must not end with `[ … ] && cmd`; a
  `var=$(f)` aborts when `f` fails. Detection helpers return 0.
- **Output** through `print_*` (`lib/ui-lib.sh`): errors to stderr, no raw
  escapes, `claude-dockerized` not `$0`.
- **Temp files** via `mktemp` in the private `TMPDIR`; replace managed files
  atomically (`atomic_install`) [T-17].
- **Test seams** that run commands are honored only with
  `CLAUDE_DOCKERIZED_TEST_HOOKS=1`.

### Supply chain

- **Pin by immutable reference:** image digests, commit SHAs for installers
  and CI actions (tag in a comment), exact versions for tools — and assert
  the installed version [T-24, T-29].
- **No `latest`, no `--lts`, no `@latest`, no unpinned `curl | bash`.**
  `tests/supply-chain.test.sh` fails otherwise.
- **Package installs never run scripts on the host** (`--ignore-scripts`,
  throwaway container) [T-14].
- **Bumps are deliberate:** Dependabot PRs for actions and the base image;
  version bumps of Node/uv/Claude/LSP in their own commit with the new pin.

## Adding an attack

1. Reproduce it as data: a case in `tests/fixtures/guard-corpus.json` (guard)
   or a `gap T-xx "…"` check in the relevant Bash suite (wrapper), tagged
   with an existing or new threat id. It must fail today (XFAIL).
2. If it is a new threat, add a row to the matrix in THREAT-MODEL.md and an
   entry in RED.md; `tests/threat-matrix.test.sh` checks that every id is
   documented and tested.
3. Fix it. The case now "unexpectedly passes" and the suite goes red: turn
   the marker into a regular check (`known_gap` removed / `gap` → `check`).
4. Update the status in THREAT-MODEL.md and the control table in BLUE.md.

## Pull request checklist (security-relevant changes)

- [ ] `bash tests/run-all.sh` green (and `--integration` when the image,
      entrypoint or runtime flags changed)
- [ ] ShellCheck clean (`uvx --from shellcheck-py shellcheck -x -S warning …`)
- [ ] New behavior has a positive **and** a negative test (blocked and still
      allowed; remote flows keep working)
- [ ] No new read-write mount, env passthrough or network access without a
      threat-model entry
- [ ] Guard version bumped if the hooks changed
- [ ] Pins updated with their asserted versions
- [ ] Docs: README (user-visible), BLUE (controls), THREAT-MODEL (status)

## Releases

Releases are **signed annotated tags** `vX.Y.Z` (`git tag -s`); `update`
refuses anything else by default. A lightweight tag is never a release, even
on a signed commit, and the target is resolved as `refs/tags/vX.Y.Z`, so a
branch with a release-like name cannot stand in for it.

Bump `WRAPPER_VERSION` in `bin/claude-dockerized` first (`tests/supply-chain.test.sh`
fails when it is behind the latest tag), then tag the release commit:

```bash
git tag -s vX.Y.Z -m "claude-dockerized vX.Y.Z"
git push origin vX.Y.Z      # release-verify.yml checks the signature
```

The maintainers' public keys live in `.github/release-keys/` (CI only).
Users pin a key themselves with `claude-dockerized update --trust-key FILE`
after checking its fingerprint through a second channel. Rotating a key:
sign the next release with the old key and announce the new fingerprint;
users pin the new key before the first release signed only by it.

## CI

- Every `uses:` pinned by commit SHA, `permissions: contents: read`,
  `persist-credentials: false`, timeouts and concurrency on every job.
- Jobs: shell lint, Dockerfile lint, all suites, guard without jq/python3,
  Docker integration (runtime contract, strict profile, hardened image),
  report-only vulnerability scan, release-tag signature check.

## Appendix — Purple, Orange and Green

- **Purple (Red ↔ Blue feedback):** every Red entry has a test; every Blue
  control names the test that proves it. The known-gap mechanism is the
  handshake: an attack enters as XFAIL, the fix turns it green, and the
  suite refuses to forget it. Re-run RED's tabletop scenarios after changes
  to mounts, the entrypoint or the guard.
- **Orange (Red → Yellow, secure-by-design training):** the rules above are
  the lessons of the audit (fail-open hooks, PATH hijack, allowlist
  shadowing, env-injectable policy, non-canonical mounts, unsigned updates,
  mutable CI tags). New contributors read RED's catalog before touching
  `hooks/` or the mount plan.
- **Green (Blue → Yellow, operability):** `doctor --json`, the integrity
  audit log and `config sync --check` are the operator's interface; keep
  their output stable and machine-readable, and add a check there whenever
  a new control can drift.
