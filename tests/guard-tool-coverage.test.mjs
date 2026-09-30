// Guard wiring: the generated managed policy (mounted at
// /etc/claude-code/managed-settings.json, the highest-precedence scope, T-03)
// routes every tool that reads or writes files through the file hook, and
// Bash through the bash hook. A tool missing from the matcher bypasses the
// guard entirely (T-09); the per-field payload cases (notebook_path, glob,
// ...) live in the bypass corpus. The user-level settings.json carries no
// hooks, env or deny rules (those would be overridable preferences).
//
// Usage: node tests/guard-tool-coverage.test.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { repo, cleanup, makeReporter } from "./lib/hook-runner.mjs";

const report = makeReporter("guard-tool-coverage");
const home = mkdtempSync(join(tmpdir(), "coverage-home-"));
const out = join(home, "managed-settings.json");
const userOut = join(home, "settings.json");

// Render both templates exactly as the wrapper does (defaults: no model, no
// cleanup override, formatters off, balanced policy).
const res = spawnSync(
  "bash",
  [
    "-c",
    'source "$1/lib/config-lib.sh" >/dev/null 2>&1; CLAUDE_MODEL=""; CLEANUP_DAYS=""; FORMATTERS_ENABLED=false; SECURITY_POLICY=balanced; write_claude_managed_settings "$2" && write_claude_settings_template "$3"',
    "_",
    repo,
    out,
    userOut,
  ],
  { encoding: "utf8", env: { ...process.env, HOME: home, CONFIG_DIR: join(home, "cfg") } },
);
report.check("templates render", res.status, 0);

const settings = JSON.parse(readFileSync(out, "utf8"));
const user = JSON.parse(readFileSync(userOut, "utf8"));
const entries = settings.hooks?.PreToolUse ?? [];
const hookFor = (tool) =>
  entries
    .filter((e) => new RegExp(`^(?:${e.matcher})$`).test(tool))
    .flatMap((e) => e.hooks.map((h) => h.command.split("/").pop()));

report.check("Bash -> bash guard", hookFor("Bash").includes("claude-guard-bash.sh"), true);
for (const tool of ["Read", "Edit", "Write", "Glob", "Grep"]) {
  report.check(`${tool} -> file guard`, hookFor(tool).includes("claude-guard-file.sh"), true);
}
for (const tool of ["MultiEdit", "NotebookEdit"]) {
  report.check(`${tool} -> file guard`, hookFor(tool).includes("claude-guard-file.sh"), true);
}
report.check("managed policy pins the policy mode", settings.env?.CLAUDE_DOCKERIZED_POLICY, "balanced");
report.check("managed policy disables auto-updates", settings.env?.DISABLE_AUTOUPDATER, "1");
report.check("managed policy disables bypass mode", settings.permissions?.disableBypassPermissionsMode, "disable");
report.check("managed policy keeps the inert sandbox off (T-30)", settings.sandbox?.enabled, false);
for (const key of ["hooks", "env", "sandbox", "disableAllHooks"]) {
  report.check(`user settings carry no ${key}`, key in user, false);
}
report.check("user settings carry no deny rules", "deny" in (user.permissions ?? {}), false);
report.check("hooks are wired by absolute path", entries.every((e) => e.hooks.every((h) => h.command.startsWith("/"))), true);

cleanup(home);
report.finish();
