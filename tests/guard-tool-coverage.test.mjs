// Guard wiring: the generated managed settings route every tool that reads or
// writes files through the file hook, and Bash through the bash hook. A tool
// missing from the matcher bypasses the guard entirely (T-09); the per-field
// payload cases (notebook_path, glob, ...) live in the bypass corpus.
//
// Usage: node tests/guard-tool-coverage.test.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { repo, cleanup, makeReporter } from "./lib/hook-runner.mjs";

const report = makeReporter("guard-tool-coverage");
const home = mkdtempSync(join(tmpdir(), "coverage-home-"));
const out = join(home, "settings.json");

// Render the template exactly as the wrapper does (defaults: no model, no
// cleanup override, formatters off).
const res = spawnSync(
  "bash",
  [
    "-c",
    'source "$1/lib/config-lib.sh" >/dev/null 2>&1; CLAUDE_MODEL=""; CLEANUP_DAYS=""; FORMATTERS_ENABLED=false; write_claude_settings_template "$2"',
    "_",
    repo,
    out,
  ],
  { encoding: "utf8", env: { ...process.env, HOME: home, CONFIG_DIR: join(home, "cfg") } },
);
report.check("template renders", res.status, 0);

const settings = JSON.parse(readFileSync(out, "utf8"));
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
  report.check(`${tool} -> file guard`, hookFor(tool).includes("claude-guard-file.sh"), true, "T-09");
}
report.check("hooks are wired by absolute path", entries.every((e) => e.hooks.every((h) => h.command.startsWith("/"))), true);

cleanup(home);
report.finish();
