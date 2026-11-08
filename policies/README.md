# Security pattern data (ported)

The `*.json` files in this directory are the rule sets from
**[opencode-policy](https://github.com/tjvjk/opencode-policy)** (`opencode-policy@0.1.4`
on npm), vendored verbatim (apart from `allow-patterns.json`, which is ours):

- `unsafe-tool-patterns.json` — unsafe shell/tool patterns (denies secret exposure,
  exfiltration, reverse shells, destructive commands, cross-workspace access, …)
- `prompt-injection-patterns.json` — instruction-override / prompt-injection patterns
- `allow-patterns.json` — **local**, not upstream: anchored allow rules (templates such as
  `.env.example`, public keys). The text an allow rule matches is cut out of the command
  and the vendored deny rules still judge the rest; the built-in backstops in the hook
  always run, and `guard-eval.js` gives no exemption to chained or substituted input
  (`;`, `&`, `|`, newlines, `$(…)`, backticks, parentheses). An allow rule that matches
  the empty string makes the engine fail closed.

## Local changes to the vendored rules

The upstream data is kept verbatim except for these edits (ids unchanged):

- **Backtracking-free forms.** Rules shaped `A.*B[.*C…]` take quadratic or cubic time
  on a long line that repeats `A` (`python -c ` × 3000 took 70 s for
  `python-while-true`, past the 30 s hook timeout). They are rewritten to
  `^(?=(?<g1>.*?A))\k<g1>(?=(?<g2>.*?B))\k<g2>.*C` with the `m` flag: per line, the
  first `A`, then the first `B` after it, is found once and never revisited (the
  lookahead + backreference makes the step atomic). The first occurrence is always the
  best one when `.*` follows it, so the rule matches exactly the same lines. Rewritten:
  `echo-base64-pipe-decode`, `python-while-true`, `fork-bomb-3`, `fork-bomb-4`,
  `npx-test-json`, `node-e-json`, `dns-exfil-4`, `symlink-etc`, `symlink-root`,
  `symlink-home`, `symlink-proc`, `time-exfil-sleep`, `reverse-shell-perl`,
  `reverse-shell-telnet`, `sed-exec`, `python-base64-decode-eval`, `awk-system`,
  `base64-payload-1`, `base64-payload-2` (the last two first lose their redundant
  `{40,}={0,2}` tail: `{40}` matches the same strings).
- **Upload options in any spelling** (case-sensitive): `curl-post-1` matches
  `-d`/`--data*`/`--json` attached (`-d@f`, `--json @f`, `--data-urlencode @f`) and
  inside a short-option cluster (`-sd@f`); `curl-form` and `curl-upload-1` do the same
  for `-F` and `-T` (`-sT/tmp/x`).

The remaining single `.*` rules stay quadratic on adversarial input; the hook bounds
them instead (commands above 64 KiB are refused and `guard-eval.js` runs under a 15 s
deadline that denies on expiry). `tests/guard-eval.test.mjs` checks that every rewritten
rule carries the `m` flag and still matches its attack.

Upstream ships them for a different agent's plugin API, so instead of depending
on that package, the generator in `lib/layer-lib.sh` copies these files to
`~/.config/claude-dockerized/hooks/policies/` (mirrored read-only into the
generated home's `hooks-guard/policies/`) and our native hook
(`hooks/claude-guard-bash.sh` via `hooks/guard-eval.js`) evaluates them with
the same first-match semantics (`new RegExp(pattern, flags ?? "i")`).

A rule may carry `admin_bypass: true` (upstream flag for rules aimed at cloud
tenants): `balanced` mode drops those, plus the IDs listed as excluded in
`hooks/guard-eval.js` (broad whole-string rules that fire on ordinary development);
`strict` keeps every rule; `none` skips the vendored set and keeps only the
built-in backstops.

To refresh the rules, replace the JSON files here (keeping the
`[{ "id", "pattern", "reason", "flags"? }]` shape), re-apply the local changes
above, and bump `VERSION` (a plain integer). `lib/layer-lib.sh` compares it with the installed copy under
`~/.config/claude-dockerized/hooks/policies/` and refreshes the rule files
(backing up the previous ones) whenever the version changes or a file is missing.
Deleting the installed copies still re-seeds them on the next run.

## License / attribution

See `LICENSE.opencode-policy` (MIT License, Copyright (c) 2026, tjvjk). Pattern
research adapted in part from `vakovalskii/topsha` (per upstream README).
