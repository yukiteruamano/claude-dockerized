// hook-runner.mjs - shared staging + invocation helpers for the guard tests.
//
// Staging mirrors production (ensure_claude_dockerized_config): the hooks,
// guard-eval.js and policies/*.json sit next to each other in one directory.
//
// Verdicts follow the Claude Code hook protocol, not "any non-zero exit":
//   exit 0                               -> "allow"
//   exit 2 + stderr starting "Blocked by" -> "deny"
//   anything else                        -> "crash:<code>"
// Claude Code treats a non-2 failure as a non-blocking error and runs the
// tool anyway, so a crashing hook is a fail-open bug, never a pass.

import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  copyFileSync,
  rmSync,
  symlinkSync,
  existsSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, delimiter } from "node:path";
import { fileURLToPath } from "node:url";

export const repo = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

export const HOOK_FILES = ["claude-guard-bash.sh", "claude-guard-file.sh", "guard-eval.js"];
export const POLICY_FILES = [
  "unsafe-tool-patterns.json",
  "prompt-injection-patterns.json",
  "allow-patterns.json",
];

// Copy the hooks and policy data into a fresh temp dir. Returns its path.
// The hooks never trust the inherited PATH (T-04): they read their tool path
// from ./hook-path (the image default otherwise), so the stage pins one —
// the test host's PATH unless `hookPath` is given.
export function stageHooks({ hookPath = process.env.PATH ?? "" } = {}) {
  const stage = mkdtempSync(join(tmpdir(), "claude-guard-"));
  mkdirSync(join(stage, "policies"), { recursive: true });
  for (const f of HOOK_FILES) copyFileSync(join(repo, "hooks", f), join(stage, f));
  for (const f of POLICY_FILES) {
    copyFileSync(join(repo, "policies", f), join(stage, "policies", f));
  }
  writeFileSync(join(stage, "hook-path"), `${hookPath}\n`);
  return stage;
}

export const cleanup = (...dirs) => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
};

// Build a PATH dir holding symlinks to every tool the hooks may call, minus
// `omit`. Used to exercise the jq/python3/node fallback paths.
const HOOK_TOOLS = [
  "bash", "cat", "dirname", "tr", "sed", "grep", "realpath", "jq", "python3",
  "node", "head", "readlink", "env", "printf",
];
export function restrictedPath(omit = []) {
  const dir = mkdtempSync(join(tmpdir(), "guard-path-"));
  for (const tool of HOOK_TOOLS) {
    if (omit.includes(tool)) continue;
    const found = which(tool);
    if (found) symlinkSync(found, join(dir, tool));
  }
  return dir;
}

export function which(tool) {
  for (const d of (process.env.PATH ?? "").split(delimiter)) {
    const p = join(d, tool);
    if (d && existsSync(p)) return realpathSync(p);
  }
  return null;
}

// Run one hook. `payload` is serialized to JSON unless `raw` (a string) is
// given. Returns { code, stderr, verdict }.
export function runHook(stage, script, { mode = "balanced", payload, raw, env = {}, cwd } = {}) {
  const input = raw ?? JSON.stringify(payload ?? {});
  const res = spawnSync("bash", [join(stage, script)], {
    input,
    encoding: "utf8",
    cwd,
    env: { ...process.env, CLAUDE_DOCKERIZED_POLICY: mode, ...env },
  });
  const code = res.status ?? -1;
  const stderr = res.stderr ?? "";
  return { code, stderr, verdict: classify(code, stderr) };
}

export function classify(code, stderr) {
  if (code === 0) return "allow";
  if (code === 2 && /^Blocked by /m.test(stderr)) return "deny";
  return `crash:${code}`;
}

// Tiny result collector shared by the .mjs suites. Known gaps (xfail) are
// cases that document a current weakness: they must still be failing; once the
// fix lands they "unexpectedly pass" and the suite asks to drop the marker.
export function makeReporter(name) {
  let failures = 0;
  let passes = 0;
  const xfails = [];
  return {
    check(label, got, want, knownGap) {
      const ok = got === want;
      if (knownGap) {
        if (ok) {
          failures++;
          console.log(`XPASS ${label} -> ${got}: known gap ${knownGap} is fixed; drop the marker`);
        } else {
          xfails.push(`${knownGap} ${label} -> ${got} (want ${want})`);
        }
        return;
      }
      if (ok) {
        passes++;
      } else {
        failures++;
        console.log(`FAIL ${label} -> ${got} (want ${want})`);
      }
    },
    finish() {
      if (xfails.length > 0 && process.env.GUARD_TEST_VERBOSE) {
        for (const x of xfails) console.log(`XFAIL ${x}`);
      }
      const summary = `${name}: ${passes} passed, ${failures} failed, ${xfails.length} known gap(s)`;
      console.log(summary);
      process.exit(failures > 0 ? 1 : 0);
    },
  };
}
