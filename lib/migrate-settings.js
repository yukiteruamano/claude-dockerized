// migrate-settings.js - helper for ensure_user_settings (lib/config-lib.sh).
//
// Usage: node migrate-settings.js <legacy> <defaults> <output>
//
// Older installs kept the wrapper policy and the user's own keys in one
// ~/.claude/settings.json. The policy now lives in the managed-settings.json
// (read-only, highest precedence), so this strips the policy keys from the
// legacy file and layers the user's remaining keys over the user defaults.
// permissions.allow entries are unioned (defaults first). A "model" key is
// dropped: the wrapper passes the default model as --model.
// Exits 2/3 when the defaults/legacy file does not parse.
// Only a Node.js builtin is imported ("node:fs").

const fs = require("node:fs");

const [legacyPath, defaultsPath, output] = process.argv.slice(2);

function readJson(path, code) {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch {
    process.exit(code);
  }
}

const defaults = readJson(defaultsPath, 2);
const legacy = readJson(legacyPath, 3);

// disableAllHooks would silence the guard hooks (T-16): never carried over.
const policyKeys = ["$schema", "hooks", "sandbox", "cleanupPeriodDays", "model", "enabledPlugins", "disableAllHooks"];
const policyPermissionKeys = ["deny", "ask", "disableBypassPermissionsMode"];

const result = { ...defaults };
for (const [key, value] of Object.entries(legacy)) {
  if (policyKeys.includes(key)) continue;
  if (key === "env") {
    const { DISABLE_AUTOUPDATER: _managed, ...userEnv } = value || {};
    if (Object.keys(userEnv).length > 0) result.env = userEnv;
    continue;
  }
  if (key === "permissions") {
    const perms = { ...(defaults.permissions || {}) };
    for (const [pk, pv] of Object.entries(value || {})) {
      if (policyPermissionKeys.includes(pk)) continue;
      if (pk === "allow" && Array.isArray(pv)) {
        perms.allow = [...new Set([...(perms.allow || []), ...pv])];
        continue;
      }
      perms[pk] = pv;
    }
    result.permissions = perms;
    continue;
  }
  result[key] = value;
}

fs.writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
