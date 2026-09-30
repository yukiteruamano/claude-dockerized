// lib/merge-settings.js contract (managed settings regeneration).
//
// Managed keys always come from the template; unknown user keys and extra
// permissions.allow entries survive; deny/ask stay template-only; keys that
// would silence the security layer never survive a merge.
//
// Usage: node tests/merge-settings.test.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { repo, cleanup, makeReporter } from "./lib/hook-runner.mjs";

const report = makeReporter("merge-settings");
const dir = mkdtempSync(join(tmpdir(), "merge-"));
const merger = join(repo, "lib/merge-settings.js");

const template = {
  $schema: "https://json.schemastore.org/claude-code-settings.json",
  env: { DISABLE_AUTOUPDATER: "1" },
  model: null,
  permissions: {
    allow: ["Bash(ls *)"],
    ask: ["Bash(git push *)"],
    deny: ["Read(./.env)"],
    disableBypassPermissionsMode: "disable",
  },
  hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "/guard.sh" }] }] },
  sandbox: { enabled: true },
  enabledPlugins: {},
};

let n = 0;
const merge = (installed, tpl = template) => {
  n++;
  const inst = join(dir, `installed-${n}.json`);
  const tplFile = join(dir, `template-${n}.json`);
  const out = join(dir, `out-${n}.json`);
  writeFileSync(inst, typeof installed === "string" ? installed : JSON.stringify(installed));
  writeFileSync(tplFile, typeof tpl === "string" ? tpl : JSON.stringify(tpl));
  const res = spawnSync("node", [merger, inst, tplFile, out], { encoding: "utf8" });
  let merged = null;
  try {
    merged = JSON.parse(readFileSync(out, "utf8"));
  } catch {
    merged = null;
  }
  const [added = "", overridden = ""] = (res.stdout ?? "").split("\n");
  return { code: res.status, merged, added: Number(added), overridden: overridden.trim().split(/\s+/).filter(Boolean) };
};

// Parse failures are distinct exit codes and never write output.
report.check("unparseable template exits 2", merge({}, "{bad").code, 2);
report.check("unparseable installed file exits 3", merge("{bad").code, 3);

// Managed keys: template wins, overrides are reported.
{
  const r = merge({
    env: { DISABLE_AUTOUPDATER: "0" },
    hooks: {},
    permissions: { allow: ["Bash(make *)"], deny: [] },
    theme: "dark",
  });
  report.check("exit 0 on a normal merge", r.code, 0);
  report.check("env comes from the template", r.merged?.env?.DISABLE_AUTOUPDATER, "1");
  report.check("hooks come from the template", r.merged?.hooks?.PreToolUse?.[0]?.hooks?.[0]?.command, "/guard.sh");
  report.check("deny list comes from the template", JSON.stringify(r.merged?.permissions?.deny), '["Read(./.env)"]');
  report.check("unknown user key survives", r.merged?.theme, "dark");
  report.check("extra user allow entry survives", r.merged?.permissions?.allow?.includes("Bash(make *)"), true);
  report.check("template allow entry kept", r.merged?.permissions?.allow?.includes("Bash(ls *)"), true);
  report.check("env override reported", r.overridden.includes("env"), true);
  report.check("deny override reported", r.overridden.includes("permissions.deny"), true);
  report.check("added count = theme + allow entry", r.added, 2);
}

// Malformed user permissions never crash the merge.
report.check("permissions as a string", merge({ permissions: "x" }).code, 0);
report.check("allow as an object", merge({ permissions: { allow: { a: 1 } } }).code, 0);
report.check(
  "template without an allow list",
  merge({ permissions: { allow: ["Bash(make *)"] } }, { ...template, permissions: { deny: [] } }).merged?.permissions
    ?.allow?.[0],
  "Bash(make *)",
);

// Keys that silence the security layer never survive (T-16).
{
  const r = merge({ disableAllHooks: true });
  report.check("disableAllHooks is dropped", r.merged?.disableAllHooks, undefined);
  report.check("disableAllHooks is reported", r.overridden.includes("disableAllHooks"), true);
}

cleanup(dir);
report.finish();
