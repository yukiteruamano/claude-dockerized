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
  // Replaced in balanced by payloadRuleId (below); strict keeps the vendored rules.
  "base64-payload-1", "base64-payload-2",
]);

// base64-payload-1/-2 fire on any 40+ character run before or after "run" or
// "exec", so a container id, a commit hash or a long path next to "npm run" /
// "docker exec" is denied. Balanced uses this narrower check instead: a
// whole-word keyword and, on the same line, a maximal token that looks like
// base64 (-1: payload after the keyword, -2: payload before it).
const BASE64_REASONS = {
  "base64-payload-1": "Exec with long base64 payload",
  "base64-payload-2": "Long base64 payload + exec request",
};
const BASE64_KEYWORD = /(?<![\p{L}\p{N}_])(?:run|exec|выполни|запусти)(?![\p{L}\p{N}_])/giu;
const BASE64_TOKEN = /(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{40,}={0,2}/g;
const BASE64_DECODER = /(?<![\p{L}\p{N}_])(?:pack|fromhex|unhex|unhexlify|xxd|hex|buffer|base64|b64decode|decode)(?![\p{L}\p{N}_])/iu;

// Lengths of hex digests and ids (sha1, sha256, sha384, sha512). A hex run of
// any other length is not an id, so it counts as a payload whatever decodes it.
const HASH_LENGTHS = new Set([40, 64, 96, 128]);

// camelCase / PascalCase / lower-case word, digits allowed after a word. Each
// extra word must start with a capital, so the pattern cannot backtrack.
const WORD = /^[A-Za-z]?[a-z]+[0-9]*(?:[A-Z][a-z]+[0-9]*)*$/;

const vowelRatio = (token) => {
  const letters = token.replace(/[^A-Za-z]/g, "");
  return letters.length === 0 ? 0 : letters.replace(/[^aeiouAEIOU]/g, "").length / letters.length;
};

// A slash-separated token whose parts are all words is a path. A single word
// with the vowel share of natural language is an identifier; random letters
// (about 19% vowels) are not.
const isPathLike = (token) => {
  const parts = token.split("/").filter(Boolean);
  return parts.length > 1 && parts.every((p) => WORD.test(p));
};
const isIdentifier = (token) => WORD.test(token) && vowelRatio(token) >= 0.3;

const looksLikeBase64 = (line, token) => {
  if (/^[0-9a-f]+$/i.test(token)) return !HASH_LENGTHS.has(token.length) || BASE64_DECODER.test(line);
  return !isPathLike(token) && !isIdentifier(token);
};

const hasPayloadToken = (line, text) =>
  [...text.matchAll(BASE64_TOKEN)].some((m) => looksLikeBase64(line, m[0]));

// Rule id of the first line with a keyword and a payload-looking token, or null.
const payloadRuleId = (value) => {
  for (const line of value.split(/[\n\r]/)) {
    const keywords = [...line.matchAll(BASE64_KEYWORD)];
    if (keywords.length === 0) continue;
    const first = keywords[0];
    const last = keywords[keywords.length - 1];
    if (hasPayloadToken(line, line.slice(first.index + first[0].length))) return "base64-payload-1";
    if (hasPayloadToken(line, line.slice(0, last.index))) return "base64-payload-2";
  }
  return null;
};

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
const payloadRule = mode === "balanced" ? payloadRuleId(value) : null;
if (payloadRule) {
  console.log(`deny|${payloadRule}|${BASE64_REASONS[payloadRule]}`);
  process.exit(0);
}
console.log("pass");
