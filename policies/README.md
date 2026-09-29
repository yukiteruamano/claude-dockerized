# Security pattern data (ported)

The `*.json` files in this directory are the rule sets from
**[opencode-policy](https://github.com/tjvjk/opencode-policy)** (`opencode-policy@0.1.4`
on npm), vendored verbatim:

- `unsafe-tool-patterns.json` — unsafe shell/tool patterns (denies secret exposure,
  exfiltration, reverse shells, destructive commands, cross-workspace access, …)
- `prompt-injection-patterns.json` — instruction-override / prompt-injection patterns

Upstream ships them for a different agent's plugin API, so instead of depending
on that package, the generator in `lib/config-lib.sh` copies these files to
`~/.config/claude-dockerized/hooks/policies/` (mirrored read-only into the
generated home's `hooks-guard/policies/`) and our native hook
(`hooks/claude-guard-bash.sh` via `hooks/guard-eval.js`) evaluates them with
the same first-match semantics (`new RegExp(pattern, flags ?? "i")`).

To refresh the rules, replace the JSON files here (keeping the
`[{ "id", "pattern", "reason", "flags"? }]` shape) and bump `VERSION` (a plain
integer). `lib/config-lib.sh` compares it with the installed copy under
`~/.config/claude-dockerized/hooks/policies/` and refreshes the rule files
(backing up the previous ones) whenever the version changes or a file is missing.
Deleting the installed copies still re-seeds them on the next run.

## License / attribution

See `LICENSE.opencode-policy` (MIT License, Copyright (c) 2026, tjvjk). Pattern
research adapted in part from `vakovalskii/topsha` (per upstream README).
