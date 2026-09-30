// guard-eval.js - vendored policy evaluation for claude-guard-bash.sh.
//
// Reads env: CGB_CMD (command text), CGB_POLICY_MODE (strict|balanced|none),
// CGB_POLICIES_DIR (dir with unsafe-tool-patterns.json,
// prompt-injection-patterns.json, allow-patterns.json).
// Prints one line: "allow", "deny|<id>|<reason>", "pass" or "error|<reason>".
// "allow" only means "skip the vendored deny rules": the calling hook still
// runs its built-in backstops. "error" (unreadable, empty or uncompilable
// policy data) makes the hook block: the guard fails closed.
// Only a Node.js builtin is imported ("node:fs", "node:path").

const fs = require("node:fs");
const path = require("node:path");

const dir = process.env.CGB_POLICIES_DIR ?? "";
const mode = process.env.CGB_POLICY_MODE ?? "balanced";
const value = process.env.CGB_CMD ?? "";

const fail = (reason) => {
  console.log(`error|${reason}`);
  process.exit(0);
};

// Load a rule file; `required` files must hold a non-empty array.
const load = (n, required) => {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(path.join(dir, n), "utf8"));
  } catch {
    fail(`policy data ${n} is missing or unreadable`);
  }
  if (!Array.isArray(parsed) || (required && parsed.length === 0)) {
    fail(`policy data ${n} is empty or malformed`);
  }
  return parsed;
};

// Rules dropped in "balanced" mode (port of the previous-generation guard:
// cloud multi-tenant rules, admin_bypass rules and whole-string false
// positives from ordinary local development; see policies/README.md).
const excluded = new Set([
  "env-var-ref", "shell-var-expansion", "bypass-var-substring",
  "bypass-var-replace", "bypass-ifs-1", "bypass-brace-cmd", "env-direct-1",
  "var-access-1", "var-access-2", "var-access-3", "dotenv-1", "dotenv-2",
  "node-dotenv", "python-env-1", "python-env-2", "python-import-environ",
  "python-subprocess-env", "node-env", "pythonpath", "node-path",
  "npx-test-json", "npx-env", "npx-dump", "npx-leak", "npx-secret",
  "npx-config", "npx-diag", "npx-debug", "npm-run-env", "node-p-process",
  "node-print-process", "kill-9", "kill-system-1", "kill-system-2",
  "sed-exec", "eval-cmd", "git-hooks", "time-exfil-sleep", "bypass-nohup",
  "bypass-disown", "bypass-setsid", "stress-1", "stress-2", "stress-test",
  "cpu-stress", "thermal-test", "urandom-bzip", "sysbench", "rustup",
  "go-install", "haskell", "pip-tensorflow", "pip-transformers", "pip-cuda",
  "pip-opencv", "npm-tensorflow", "base64-pipe-2", "xxd-tool", "hexdump-tool",
  "od-tool", "cd-parent-workspace", "cd-dotdot-in-script",
  "workspace-root-direct", "workspace-root-ls", "shared-dir-access",
  "find-workspace", "history-1", "dns-exfil-3", "exec-builtin", "fork-bomb-2",
  "env-direct-2", "at-schedule", "base64-exfil-1", "dos-yes", "dos-yes-pipe",
  // Any ampersand inside a loop body (2>&1, &&) matches these, not only a background job.
  "fork-bomb-3", "fork-bomb-4",
]);

// Build every rule or fail closed: a pattern that does not compile would
// otherwise be a silently lost rule.
const build = (rules, name) =>
  rules.map((rule) => {
    if (!rule || typeof rule.pattern !== "string") fail(`policy data ${name} has a rule without a pattern`);
    try {
      return {
        id: rule.id,
        reason: rule.reason,
        adminBypass: rule.admin_bypass === true,
        re: new RegExp(rule.pattern, rule.flags ?? "i"),
      };
    } catch {
      return fail(`policy data ${name}: rule ${rule.id} does not compile`);
    }
  });

const allowRules = build(load("allow-patterns.json", false), "allow-patterns.json");
const denySets = ["unsafe-tool-patterns.json", "prompt-injection-patterns.json"].map((n) =>
  build(load(n, true), n),
);

// An allow rule never applies to chained/multi-line commands.
if (!/[;&|\n\r]/.test(value)) {
  for (const rule of allowRules) {
    if (rule.re.test(value)) {
      console.log("allow");
      process.exit(0);
    }
  }
}

const select = (rules) =>
  mode === "strict" ? rules : rules.filter((r) => !r.adminBypass && !excluded.has(r.id));

for (const rules of denySets) {
  for (const rule of select(rules)) {
    if (rule.re.test(value)) {
      console.log(`deny|${rule.id}|${rule.reason ?? ""}`);
      process.exit(0);
    }
  }
}
console.log("pass");
