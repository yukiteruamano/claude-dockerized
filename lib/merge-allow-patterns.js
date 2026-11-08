// merge-allow-patterns.js - helper for allow_patterns_render (lib/layer-lib.sh)
// and `profile approve NAME allow-patterns` (lib/profile-cmd-lib.sh).
//
// Usage: node merge-allow-patterns.js <global> <profile> [<output>]
//
// A profile may add allow rules to the guard (T-36). They are validated the
// way hooks/guard-eval.js builds them (a pattern that does not compile would
// be a silently lost rule there), may not reuse a global id, and are
// appended after the global rules. Without <output> only the validation
// runs and the profile rules are listed ("id<TAB>pattern" per line).
// Exits 2 when the global file does not parse, 3 when the profile file is
// invalid (the reason goes to stderr).
// Only a Node.js builtin is imported ("node:fs").

const fs = require("node:fs");

const [globalPath, profilePath, output] = process.argv.slice(2);

function fail(code, reason) {
  process.stderr.write(`${reason}\n`);
  process.exit(code);
}

function readJson(path, code) {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch {
    return fail(code, `${path} is not valid JSON`);
  }
}

const globalRules = readJson(globalPath, 2);
if (!Array.isArray(globalRules)) fail(2, `${globalPath} is not a JSON array`);
const profileRules = readJson(profilePath, 3);
if (!Array.isArray(profileRules)) fail(3, "the profile allow-patterns file must be a JSON array");
if (profileRules.length > 64) fail(3, "at most 64 profile allow rules");

const ids = new Set(globalRules.map((rule) => rule && rule.id));
for (const [i, rule] of profileRules.entries()) {
  const where = `rule ${i + 1}`;
  if (!rule || typeof rule !== "object" || Array.isArray(rule)) fail(3, `${where} is not an object`);
  const extra = Object.keys(rule).filter((k) => !["id", "pattern", "reason", "flags"].includes(k));
  if (extra.length) fail(3, `${where} has unknown keys: ${extra.join(", ")}`);
  if (typeof rule.id !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(rule.id)) {
    fail(3, `${where} needs an id of lowercase letters, digits and -`);
  }
  if (ids.has(rule.id)) fail(3, `${where}: id ${rule.id} is already used`);
  ids.add(rule.id);
  if (typeof rule.pattern !== "string" || rule.pattern.length === 0 || rule.pattern.length > 512) {
    fail(3, `${where} (${rule.id}) needs a pattern of 1-512 characters`);
  }
  if (typeof rule.reason !== "string" || rule.reason.trim() === "") fail(3, `${where} (${rule.id}) needs a reason`);
  if (rule.flags !== undefined && (typeof rule.flags !== "string" || !/^[imsu]*$/.test(rule.flags))) {
    fail(3, `${where} (${rule.id}) has invalid flags (use i, m, s, u)`);
  }
  try {
    new RegExp(rule.pattern, rule.flags ?? "i");
  } catch {
    fail(3, `${where} (${rule.id}) does not compile`);
  }
}

if (!output) {
  for (const rule of profileRules) process.stdout.write(`${rule.id}\t${rule.pattern}\n`);
  process.exit(0);
}
fs.writeFileSync(output, `${JSON.stringify([...globalRules, ...profileRules], null, 2)}\n`);
