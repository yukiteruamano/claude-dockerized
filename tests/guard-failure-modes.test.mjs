// Guard failure modes: what the hooks do when their inputs or their own
// dependencies are broken or hostile.
//
// Target behaviour is fail-closed: a payload that cannot be parsed, missing or
// corrupt policy data, an unknown policy mode or a hijacked helper binary must
// block (exit 2), never let the tool call through (threats T-03, T-04, T-11).
//
// Usage: node tests/guard-failure-modes.test.mjs

import { mkdtempSync, mkdirSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  stageHooks,
  runHook,
  cleanup,
  makeReporter,
  restrictedPath,
} from "./lib/hook-runner.mjs";

const report = makeReporter("guard-failure-modes");
const root = mkdtempSync(join(tmpdir(), "guard-fail-"));
const PROJECT = join(root, "project");
const OUTSIDE = join(root, "outside");
mkdirSync(PROJECT, { recursive: true });
mkdirSync(OUTSIDE, { recursive: true });

const bashPayload = (command) => ({ tool_name: "Bash", tool_input: { command } });
const writePayload = (file_path) => ({ tool_name: "Write", tool_input: { file_path, content: "x" } });
const SECRET_READ = bashPayload("cat .env");
const VENDORED_ONLY = bashPayload("nmap 10.0.0.1"); // blocked only by vendored rules
const DEV_IDIOM = bashPayload("cd .. && ls"); // blocked only in strict

const stages = [];
const freshStage = (opts) => {
  const s = stageHooks(opts);
  stages.push(s);
  return s;
};
const base = freshStage();

// A clean dir with every helper binary: the hooks' trusted path (./hook-path)
// in the fake-tool cases below, so only PATH (attacker-influenced) has fakes.
const fullTools = restrictedPath([]);
const env = (extra = {}) => ({ CLAUDE_PROJECT_DIR: PROJECT, ...extra });
const bash = (stage, opts) => runHook(stage, "claude-guard-bash.sh", opts).verdict;
const file = (stage, opts) => runHook(stage, "claude-guard-file.sh", opts).verdict;

// --- Unparseable / empty payloads ---
report.check("bash: malformed JSON", bash(base, { raw: "{not json", env: env() }), "deny");
report.check("bash: empty stdin", bash(base, { raw: "", env: env() }), "deny");
report.check("file: malformed JSON", file(base, { raw: "{not json", env: env() }), "deny");
report.check(
  "bash: payload without a command is a no-op",
  bash(base, { payload: { tool_name: "Bash", tool_input: {} }, env: env() }),
  "allow",
);

// --- Missing helper tools (fallback parsers) ---
for (const omit of [["jq"], ["jq", "python3"], ["jq", "python3", "node"]]) {
  const p = restrictedPath(omit);
  const s = freshStage({ hookPath: p });
  const e = env({ PATH: p });
  report.check(`bash without ${omit.join("+")}: secret read`, bash(s, { payload: SECRET_READ, env: e }), "deny");
  report.check(
    `file without ${omit.join("+")}: write outside project`,
    file(s, { payload: writePayload(join(OUTSIDE, "x")), env: e }),
    "deny",
  );
}
{
  const p = restrictedPath(["node"]);
  report.check(
    "bash without node: vendored rules must not silently turn off",
    bash(freshStage({ hookPath: p }), { payload: VENDORED_ONLY, env: env({ PATH: p }) }),
    "deny",
  );
}

// --- Corrupt / missing policy data ---
{
  const s = freshStage();
  writeFileSync(join(s, "policies/unsafe-tool-patterns.json"), "{ corrupt");
  report.check("corrupt policy JSON", bash(s, { payload: VENDORED_ONLY, env: env() }), "deny");
}
{
  const s = freshStage();
  writeFileSync(join(s, "policies/unsafe-tool-patterns.json"), "[]");
  writeFileSync(join(s, "policies/prompt-injection-patterns.json"), "[]");
  report.check("emptied policy data", bash(s, { payload: VENDORED_ONLY, env: env() }), "deny");
}
{
  const s = freshStage();
  writeFileSync(
    join(s, "policies/prompt-injection-patterns.json"),
    JSON.stringify([{ id: "broken", pattern: "(", reason: "invalid regex" }]),
  );
  report.check("uncompilable policy pattern", bash(s, { payload: bashPayload("ls"), env: env() }), "deny");
}

// --- Policy mode resolution ---
report.check("mode STRICT folds to strict", bash(base, { mode: "STRICT", payload: DEV_IDIOM, env: env() }), "deny");
report.check("unknown mode fails closed to strict", bash(base, { mode: "bogus", payload: DEV_IDIOM, env: env() }), "deny");
{
  // The wrapper writes the mode next to the hooks (read-only mount); an env
  // override (e.g. from project settings "env") must not relax it.
  const s = freshStage();
  writeFileSync(join(s, "policy-mode"), "strict\n");
  report.check(
    "policy-mode file wins over env",
    bash(s, { mode: "none", payload: DEV_IDIOM, env: env() }),
    "deny",
  );
}

// --- Hijacked helper binaries earlier on PATH (writable ~/.local/bin) ---
{
  const fake = join(root, "fakebin");
  mkdirSync(fake, { recursive: true });
  for (const [tool, body] of [
    ["jq", "#!/bin/sh\ncat >/dev/null\nexit 0\n"],
    ["node", "#!/bin/sh\necho allow\n"],
  ]) {
    writeFileSync(join(fake, tool), body);
    chmodSync(join(fake, tool), 0o755);
  }
  const trusted = freshStage({ hookPath: fullTools });
  const e = env({ PATH: `${fake}:${process.env.PATH}` });
  report.check("fake jq on PATH: secret read", bash(trusted, { payload: SECRET_READ, env: e }), "deny");
  report.check(
    "fake node on PATH: privilege escalation",
    bash(trusted, { payload: bashPayload("sudo ls"), env: e }),
    "deny",
  );
  report.check(
    "fake jq on PATH: file write outside project",
    file(trusted, { payload: writePayload(join(OUTSIDE, "x")), env: e }),
    "deny",
  );
}

// --- Inputs that would outlast the hook timeout (Claude Code runs the tool then) ---
{
  const huge = bashPayload(`echo ${"a ".repeat(40000)}`);
  report.check("command above 64 KiB is refused", bash(base, { payload: huge, env: env() }), "deny");
  for (const [label, command] of [
    ["python -c (cubic vendored rule)", "python -c ".repeat(3000)],
    ["curl x (quadratic vendored rules)", "curl x ".repeat(9000)],
  ]) {
    const started = Date.now();
    const verdict = bash(base, { mode: "strict", payload: bashPayload(command), env: env() });
    const seconds = (Date.now() - started) / 1000;
    report.check(`${label}: decided without crashing`, verdict === "allow" || verdict === "deny", true);
    report.check(`${label}: well below the 30 s hook timeout (${seconds.toFixed(1)} s)`, seconds < 20, true);
  }
}
{
  // A policy engine that hangs is killed at the deadline and the call refused.
  const s = freshStage();
  writeFileSync(join(s, "guard-eval.js"), "setInterval(() => {}, 1000);\n");
  writeFileSync(join(s, "engine-seconds"), "1\n");
  const res = runHook(s, "claude-guard-bash.sh", { payload: bashPayload("ls"), env: env() });
  report.check("hung policy engine: denied at the deadline", res.verdict, "deny");
  report.check("hung policy engine: the reason says it timed out", /timed out/.test(res.stderr), true);
}
{
  const p = restrictedPath(["timeout"]);
  report.check(
    "bash without timeout: the policy engine never runs unbounded",
    bash(freshStage({ hookPath: p }), { payload: bashPayload("ls"), env: env({ PATH: p }) }),
    "deny",
  );
}

// --- Project paths with shell-special characters stay one root ---
{
  const pipeProject = join(root, "a|b");
  const sibling = join(root, "a");
  const globProject = join(root, "pro*");
  for (const d of [pipeProject, sibling, globProject]) mkdirSync(d, { recursive: true });
  report.check(
    "project dir with | : writes inside it are allowed",
    file(base, { payload: writePayload(join(pipeProject, "x")), env: env({ CLAUDE_PROJECT_DIR: pipeProject }) }),
    "allow",
  );
  report.check(
    "project dir with | : its prefix is not a root",
    file(base, { payload: writePayload(join(sibling, "x")), env: env({ CLAUDE_PROJECT_DIR: pipeProject }) }),
    "deny",
  );
  report.check(
    "project dir with * : never expanded to other directories",
    file(base, { payload: writePayload(join(PROJECT, "x")), env: env({ CLAUDE_PROJECT_DIR: globProject }) }),
    "deny",
  );
}

// --- A payload the parsers do not understand fails closed (non-string tool_name) ---
for (const omit of [[], ["jq"], ["jq", "python3"]]) {
  const p = restrictedPath(omit);
  const s = freshStage({ hookPath: p });
  const payload = { tool_name: 5, tool_input: { file_path: join(OUTSIDE, "x"), content: "x" } };
  report.check(
    `file${omit.length ? ` without ${omit.join("+")}` : ""}: numeric tool_name, write outside project`,
    file(s, { payload, env: env({ PATH: p }) }),
    "deny",
  );
}

cleanup(root, fullTools, ...stages);
report.finish();
