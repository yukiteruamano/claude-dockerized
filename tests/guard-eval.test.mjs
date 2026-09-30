// guard-eval.js contract: vendored policy data integrity and evaluator output.
//
// - every vendored pattern compiles with its flags (a pattern that does not
//   compile is silently dropped by the evaluator, i.e. a lost rule)
// - rule ids are unique, and every id in the balanced-mode exclusion list
//   exists, so a renamed upstream id cannot silently re-enable or disable one
// - allow rules never apply to chained / multi-line input
// - output format is exactly "allow" | "deny|<id>|<reason>" | "pass"
//
// Usage: node tests/guard-eval.test.mjs

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { repo, stageHooks, cleanup, makeReporter } from "./lib/hook-runner.mjs";

const report = makeReporter("guard-eval");
const load = (name) => JSON.parse(readFileSync(join(repo, "policies", name), "utf8"));

const unsafe = load("unsafe-tool-patterns.json");
const injection = load("prompt-injection-patterns.json");
const allow = load("allow-patterns.json");

// --- Data integrity ---
for (const [name, rules] of [
  ["unsafe-tool-patterns.json", unsafe],
  ["prompt-injection-patterns.json", injection],
  ["allow-patterns.json", allow],
]) {
  report.check(`${name} is a non-empty array`, Array.isArray(rules) && rules.length > 0, true);
  const seen = new Set();
  for (const rule of rules) {
    let compiles = true;
    try {
      new RegExp(rule.pattern, rule.flags ?? "i");
    } catch {
      compiles = false;
    }
    report.check(`${name}: ${rule.id} compiles`, compiles, true);
    report.check(`${name}: ${rule.id} id is unique`, seen.has(rule.id), false);
    seen.add(rule.id);
  }
}

const evalSource = readFileSync(join(repo, "hooks/guard-eval.js"), "utf8");
const excludedBlock = evalSource.match(/const excluded = new Set\(\[([\s\S]*?)\]\)/);
report.check("exclusion list is present", Boolean(excludedBlock), true);
const excluded = [...(excludedBlock?.[1] ?? "").matchAll(/"([^"]+)"/g)].map((m) => m[1]);
const vendoredIds = new Set([...unsafe, ...injection].map((r) => r.id));
for (const id of excluded) {
  report.check(`excluded id ${id} exists in the vendored set`, vendoredIds.has(id), true);
}

// --- Evaluator behaviour ---
const stage = stageHooks();
const evaluate = (value, mode = "balanced") => {
  const res = spawnSync("node", [join(stage, "guard-eval.js")], {
    encoding: "utf8",
    env: {
      ...process.env,
      CGB_CMD: value,
      CGB_POLICY_MODE: mode,
      CGB_POLICIES_DIR: join(stage, "policies"),
    },
  });
  return (res.stdout ?? "").trim();
};
const FORMAT = /^(allow|pass|deny\|[^|\n]+\|[^\n]*)$/;

for (const value of ["cat .env.example", "ls", "nmap 10.0.0.1"]) {
  report.check(`output format for "${value}"`, FORMAT.test(evaluate(value)), true);
}
report.check("template read is allowed", evaluate("cat .env.example"), "allow");
for (const chained of [
  "cat .env.example; id",
  "cat .env.example && id",
  "cat .env.example | sh",
  "cat .env.example\nid",
]) {
  report.check(`allow never applies to chained input: ${JSON.stringify(chained)}`, evaluate(chained) === "allow", false);
}
report.check("vendored deny carries its rule id", evaluate("nmap 10.0.0.1", "strict").startsWith("deny|"), true);
report.check("mode none still reports pass for plain commands", evaluate("ls", "none"), "pass");

cleanup(stage);
report.finish();
