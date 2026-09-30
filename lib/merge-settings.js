// merge-settings.js - merge helper for merge_claude_permissions (lib/config-lib.sh).
//
// Usage: node merge-settings.js <installed> <template> <output>
//
// Managed keys always come from the template (template wins; keys the
// template lacks are dropped, e.g. hooks/env/sandbox, which now live in the
// managed policy, and disableAllHooks, which would silence it); unknown user
// keys and extra permissions.allow entries are preserved in the output.
// Prints "<added>\n<space-separated overridden managed keys>".
// Exits 2/3 when the template/installed file does not parse.
// Only a Node.js builtin is imported ("node:fs").

const fs = require("node:fs");

const [installed, template, output] = process.argv.slice(2);

let base;
let user;
try {
  base = JSON.parse(fs.readFileSync(template, "utf8"));
} catch {
  process.exit(2);
}
try {
  user = JSON.parse(fs.readFileSync(installed, "utf8"));
} catch {
  process.exit(3);
}

const managed = [
  "$schema",
  "env",
  "permissions",
  "hooks",
  "sandbox",
  "cleanupPeriodDays",
  "model",
  "enabledPlugins",
  "disableAllHooks",
];

// Keys derived from the wrapper config (setting.model, cleanup_days,
// formatters): a changed value is the config speaking, not a user edit, so
// the template still wins but the change is not reported as an override.
const derived = ["$schema", "model", "cleanupPeriodDays", "enabledPlugins"];

let added = 0;
const overridden = [];
for (const k of Object.keys(user)) {
  if (managed.includes(k)) {
    if (!derived.includes(k) && JSON.stringify(user[k]) !== JSON.stringify(base[k])) overridden.push(k);
    continue;
  }
  base[k] = user[k];
  added++;
}

// Merge extra user allow-entries (deny/ask stay template-only by design).
if (user.permissions && Array.isArray(user.permissions.allow) && base.permissions) {
  base.permissions.allow = base.permissions.allow || [];
  for (const entry of user.permissions.allow) {
    if (!base.permissions.allow.includes(entry)) {
      base.permissions.allow.push(entry);
      added++;
    }
  }
  for (const k of ["deny", "ask"]) {
    const a = JSON.stringify((user.permissions || {})[k]);
    const b = JSON.stringify((base.permissions || {})[k]);
    if (a !== undefined && a !== b) overridden.push("permissions." + k);
  }
}

fs.writeFileSync(output, JSON.stringify(base, null, 2) + "\n");
console.log(added + "\n" + overridden.join(" "));
