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
  // Whole-string prose rules (decode, then a later run): any `decode` before a
  // later `run` in a chained command matches. Replaced in balanced by DECODE_EXEC.
  "base64-decode-exec-en-1", "base64-decode-exec-ru-1",
  // Same class as the already excluded xxd-tool / base64-exfil-1; secret files
  // stay covered by the hook's leak backstops.
  "xxd-exfil",
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
// `xxd` only decodes with -r; a plain `xxd file` is a hex dump, not a decoder.
const BASE64_DECODER = /(?<![\p{L}\p{N}_])(?:pack|fromhex|unhex|unhexlify|xxd\s+-[a-z]*r|hex|buffer|base64|b64decode|decode)(?![\p{L}\p{N}_])/iu;

// Lengths of hex digests and ids (md5, sha1, sha224, sha256, sha384, sha512);
// with the 0x prefix they are also EVM addresses and transaction hashes. A hex
// run of any other length is not an id, so it counts as a payload whatever
// decodes it.
const HASH_LENGTHS = new Set([32, 40, 56, 64, 96, 128]);

// camelCase / PascalCase / lower-case word, digits allowed around a word (a
// timestamped migration name starts with digits). Each extra word must start
// with a capital, so the pattern cannot backtrack.
const WORD = /^[0-9]*[A-Za-z]?[a-z]+[0-9]*(?:[A-Z][a-z]+[0-9]*)*$/;
// Directory or file part written in capitals or digits only (/WORK/, /HOME/, 2026).
const ACRONYM = /^[A-Z0-9]+$/;
// Bech32 addresses (bc1q..., tb1p..., ltc1...): lower-case, no random casing.
const BECH32 = /^(?:bc|tb|ltc|bcrt)1[a-z0-9]{38,}$/;

const LONG_HEX = /^(?:0x)?[0-9a-f]{24,}$/i;

// A token shorter than this after the benign parts are removed is not a payload.
const MIN_PAYLOAD = 32;

const vowelRatio = (token) => {
  const letters = token.replace(/[^A-Za-z]/g, "");
  return letters.length === 0 ? 0 : letters.replace(/[^aeiouAEIOU]/g, "").length / letters.length;
};

// A hex id of a known length is benign unless a decoder word shares the line.
const isHexId = (part, line) => {
  const hex = part.replace(/^0x/i, "");
  return /^[0-9a-f]+$/i.test(hex) && HASH_LENGTHS.has(hex.length) && !BASE64_DECODER.test(line);
};

// `multi` = the token has several slash-separated parts, i.e. it is a path: its
// parts may be capitals, digits or short words ("src", "lib") with few vowels. A
// lone word still needs the vowel share of natural language, because random
// letters (about 19% vowels) are not an identifier.
const isBenignPart = (part, line, multi) => {
  // A long hex run ("deadbeef..." also reads as a word) is benign only as a digest or id.
  if (LONG_HEX.test(part)) return isHexId(part, line);
  return (
    BECH32.test(part) ||
    (WORD.test(part) && (multi || vowelRatio(part) >= 0.3)) ||
    (multi && ACRONYM.test(part))
  );
};

// Characters of the token that are not explained by a path part or an id. Parts
// are measured one by one, so a path with one odd segment (a digest, a hash) does
// not hide a payload and a payload with a slash inside it is still measured whole.
const unexplainedLength = (line, token) => {
  const parts = token.split("/").filter(Boolean);
  const multi = parts.length > 1;
  return parts.reduce((sum, p) => sum + (isBenignPart(p, line, multi) ? 0 : p.length), 0);
};

const looksLikeBase64 = (line, token) => unexplainedLength(line, token) >= MIN_PAYLOAD;

// Narrow replacement for "decode ... run": a decoder (base64 -d, b64decode, atob)
// whose output is evaluated on the same line (eval / source / sh -c / bash -c).
const DECODE_EXEC = /(?<![\p{L}\p{N}_])(?:eval|source|(?:ba|z)?sh\s+-c)(?![\p{L}\p{N}_])[^\n\r]*(?:base64\s+(?:-d|-D|--decode)|b64decode|atob\s*\()/iu;

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
if (mode === "balanced" && DECODE_EXEC.test(value)) {
  console.log("deny|base64-decode-exec-line|Decoded output evaluated (eval/source/sh -c)");
  process.exit(0);
}
console.log("pass");
