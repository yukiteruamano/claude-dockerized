// Guard bypass corpus: data-driven Red-team regression cases.
//
// Cases live in tests/fixtures/guard-corpus.json (see its _comment for the
// schema). Every case runs in strict, balanced and none; `expect` may be a
// single verdict or a per-mode map. Cases marked `known_gap` document a
// current weakness and are reported as XFAIL until the fix lands.
//
// Usage: node tests/guard-bypass-corpus.test.mjs   (GUARD_TEST_VERBOSE=1 lists gaps)

import { readFileSync, mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stageHooks, runHook, cleanup, makeReporter, repo } from "./lib/hook-runner.mjs";

const corpus = JSON.parse(readFileSync(join(repo, "tests/fixtures/guard-corpus.json"), "utf8"));
const stage = stageHooks();

const root = mkdtempSync(join(tmpdir(), "corpus-"));
const dirs = {
  PROJECT: join(root, "project"),
  OUTSIDE: join(root, "outside"),
  HOME: join(root, "home"),
};
mkdirSync(join(dirs.PROJECT, "src"), { recursive: true });
mkdirSync(join(dirs.PROJECT, ".git/hooks"), { recursive: true });
mkdirSync(dirs.OUTSIDE, { recursive: true });
mkdirSync(dirs.HOME, { recursive: true });
writeFileSync(join(dirs.PROJECT, ".git/config"), "[core]\n");

const substitute = (value) => {
  if (typeof value === "string") {
    return value.replace(/\{(PROJECT|OUTSIDE|HOME)\}/g, (_, k) => dirs[k]);
  }
  if (Array.isArray(value)) return value.map(substitute);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, substitute(v)]));
  }
  return value;
};

const SCRIPTS = { bash: "claude-guard-bash.sh", file: "claude-guard-file.sh" };
const MODES = ["strict", "balanced", "none"];
const report = makeReporter("guard-bypass-corpus");

const ids = new Set();
for (const c of corpus.cases) {
  if (ids.has(c.id)) throw new Error(`duplicate corpus id: ${c.id}`);
  ids.add(c.id);
  if (!/^T-\d{2}$/.test(c.threat ?? "")) throw new Error(`case ${c.id} has no threat id`);
  const script = SCRIPTS[c.hook];
  if (!script) throw new Error(`case ${c.id}: unknown hook ${c.hook}`);
  const payload = substitute(c.payload);
  for (const mode of MODES) {
    const want = typeof c.expect === "string" ? c.expect : c.expect[mode];
    const gap = typeof c.known_gap === "object" ? c.known_gap?.[mode] : c.known_gap;
    const { verdict } = runHook(stage, script, {
      mode,
      payload,
      env: { CLAUDE_PROJECT_DIR: dirs.PROJECT, HOME: dirs.HOME, ...(c.env ?? {}) },
      cwd: dirs.PROJECT,
    });
    report.check(`[${mode}] ${c.threat} ${c.id}`, verdict, want, gap);
  }
}

cleanup(stage, root);
report.finish();
