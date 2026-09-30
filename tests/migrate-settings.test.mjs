// lib/migrate-settings.js contract (legacy user settings.json migration).
//
// The policy keys of an old single-file settings.json (hooks, deny/ask, the
// auto-update env flag, sandbox, model, ...) are stripped because they now
// live in the managed policy; the user's own keys survive, layered over the
// user defaults; permissions.allow is unioned; keys that would silence the
// security layer never survive (T-16).
//
// Usage: node tests/migrate-settings.test.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { repo, cleanup, makeReporter } from "./lib/hook-runner.mjs";

const report = makeReporter("migrate-settings");
const dir = mkdtempSync(join(tmpdir(), "migrate-"));
const migrator = join(repo, "lib/migrate-settings.js");

const defaults = {
  $schema: "https://json.schemastore.org/claude-code-settings.json",
  permissions: { defaultMode: "default", allow: ["Bash(ls *)"] },
};

let n = 0;
const migrate = (legacy, defs = defaults) => {
  n++;
  const legacyFile = join(dir, `legacy-${n}.json`);
  const defsFile = join(dir, `defaults-${n}.json`);
  const out = join(dir, `out-${n}.json`);
  writeFileSync(legacyFile, typeof legacy === "string" ? legacy : JSON.stringify(legacy));
  writeFileSync(defsFile, typeof defs === "string" ? defs : JSON.stringify(defs));
  const res = spawnSync("node", [migrator, legacyFile, defsFile, out], { encoding: "utf8" });
  let migrated = null;
  try {
    migrated = JSON.parse(readFileSync(out, "utf8"));
  } catch {
    migrated = null;
  }
  return { code: res.status, migrated, wrote: existsSync(out) };
};

// Parse failures are distinct exit codes and never write output.
{
  const r = migrate({}, "{bad");
  report.check("unparseable defaults exit 2", r.code, 2);
  report.check("unparseable defaults write nothing", r.wrote, false);
}
report.check("unparseable legacy file exits 3", migrate("{bad").code, 3);

// Policy keys are stripped; user keys survive over the defaults.
{
  const r = migrate({
    $schema: "legacy",
    env: { DISABLE_AUTOUPDATER: "1", MY_FLAG: "x" },
    hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: "command", command: "/guard.sh" }] }] },
    sandbox: { enabled: true },
    model: "opus",
    cleanupPeriodDays: 3,
    enabledPlugins: { "x@y": true },
    permissions: {
      allow: ["Bash(make *)", "Bash(ls *)"],
      deny: ["Read(./secret.txt)"],
      ask: ["Bash(git push *)"],
      disableBypassPermissionsMode: "disable",
      additionalDirectories: ["/work"],
    },
    theme: "dark",
  });
  report.check("exit 0 on a normal migration", r.code, 0);
  report.check("$schema comes from the defaults", r.migrated?.$schema, defaults.$schema);
  for (const key of ["hooks", "sandbox", "model", "cleanupPeriodDays", "enabledPlugins"]) {
    report.check(`policy key ${key} is stripped`, key in (r.migrated ?? {}), false);
  }
  report.check("managed env flag is stripped", r.migrated?.env?.DISABLE_AUTOUPDATER, undefined);
  report.check("user env entry survives", r.migrated?.env?.MY_FLAG, "x");
  for (const key of ["deny", "ask", "disableBypassPermissionsMode"]) {
    report.check(`permissions.${key} is stripped`, key in (r.migrated?.permissions ?? {}), false);
  }
  report.check(
    "allow is unioned, defaults first",
    JSON.stringify(r.migrated?.permissions?.allow),
    '["Bash(ls *)","Bash(make *)"]',
  );
  report.check("other user permission keys survive", r.migrated?.permissions?.additionalDirectories?.[0], "/work");
  report.check("default permission keys kept", r.migrated?.permissions?.defaultMode, "default");
  report.check("unknown user key survives", r.migrated?.theme, "dark");
}

// An env block holding only the managed flag leaves no env behind.
report.check(
  "env with only the managed flag is dropped",
  "env" in (migrate({ env: { DISABLE_AUTOUPDATER: "1" } }).migrated ?? {}),
  false,
);

// Keys that silence the security layer never survive (T-16).
report.check(
  "disableAllHooks is dropped (T-16)",
  "disableAllHooks" in (migrate({ disableAllHooks: true }).migrated ?? {}),
  false,
);

cleanup(dir);
report.finish();
