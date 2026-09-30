#!/bin/bash
# Session integrity check (lib/integrity-lib.sh; Blue-team detection for
# T-01, T-05): every change to a persistent path the session could plant
# code in is reported and logged; ordinary Claude state churn is not.
#
# Usage: bash tests/integrity.test.sh
# shellcheck disable=SC2034,SC2317  # globals feed config-lib.sh; helpers run via check

# No `set -u`: config-lib.sh is sourced by callers that do not use it.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="integrity"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export NO_COLOR=1
PROJECT="$HOME/work/proj"
mkdir -p "$PROJECT/.git/hooks" "$PROJECT/src" "$CCODE_HOME/.local/bin" "$CCODE_HOME/.claude/plugins" \
    "$CCODE_HOME/.claude/skills"
printf '[core]\n' >"$PROJECT/.git/config"
printf '{"numStartups":1,"mcpServers":{}}\n' >"$CCODE_HOME/.claude.json"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"

AUDIT="$CONFIG_DIR/audit/sessions.jsonl"
BEFORE="$TMP/before"
AFTER="$TMP/after"

# session <mutation...> — snapshot, run the mutation, snapshot, report.
# Sets OUT (terminal report) and RC (0 = clean).
session() {
    integrity_snapshot "$PROJECT" "$BEFORE"
    "$@"
    integrity_snapshot "$PROJECT" "$AFTER"
    RC=0
    OUT="$(integrity_report "$PROJECT" "$BEFORE" "$AFTER" 2>&1)" || RC=$?
}
reported() { has_text "$1" "$OUT"; }
noop() { :; }

# --- no change, no report ----------------------------------------------------------------
session noop
assert_eq "$RC" 0 "an untouched session reports nothing"
check_not "no audit log without changes" [ -s "$AUDIT" ]

# --- ordinary work is not reported --------------------------------------------------------
edit_source() { printf 'x\n' >"$PROJECT/src/a.ts"; }
session edit_source
assert_eq "$RC" 0 "editing project sources is not reported"
churn_state() { printf '{"numStartups":2,"mcpServers":{}}\n' >"$CCODE_HOME/.claude.json"; }
session churn_state
assert_eq "$RC" 0 "Claude state churn in .claude.json is not reported"

# --- planted persistence is reported ----------------------------------------------------------
plant_git_hook() { printf '#!/bin/sh\n' >"$PROJECT/.git/hooks/post-checkout"; chmod +x "$PROJECT/.git/hooks/post-checkout"; }
session plant_git_hook
assert_eq "$RC" 1 "a new git hook is reported (T-01)"
check "report names the git hook" reported ".git/hooks/post-checkout"

edit_git_config() { printf '[core]\n\tfsmonitor = ./x\n' >"$PROJECT/.git/config"; }
session edit_git_config
check "a git config change is reported (T-01)" reported ".git/config"

project_settings() { mkdir -p "$PROJECT/.claude"; printf '{}\n' >"$PROJECT/.claude/settings.local.json"; }
session project_settings
check "new project Claude settings are reported (T-03)" reported ".claude/settings.local.json"

plant_bin() { printf '#!/bin/sh\n' >"$CCODE_HOME/.local/bin/node"; }
session plant_bin
check "a binary planted in ~/.local/bin is reported (T-04)" reported ".local/bin/node"

add_mcp() { printf '{"numStartups":3,"mcpServers":{"evil":{"command":"sh"}}}\n' >"$CCODE_HOME/.claude.json"; }
session add_mcp
check "a new MCP server is reported (T-05)" reported ".claude.json#mcpServers"

add_skill() { mkdir -p "$CCODE_HOME/.claude/skills/x"; printf 'x\n' >"$CCODE_HOME/.claude/skills/x/SKILL.md"; }
session add_skill
check "a new skill is reported (T-05)" reported ".claude/skills/x/SKILL.md"

chmod_hook() { chmod -x "$PROJECT/.git/hooks/post-checkout"; }
session chmod_hook
check "a mode change is reported" reported ".git/hooks/post-checkout"

symlink_bin() { ln -s /bin/sh "$CCODE_HOME/.local/bin/git"; }
session symlink_bin
check "a planted symlink is reported" reported ".local/bin/git"

# mtimes can be forged: content hashing still sees the change.
forged_mtime() {
    printf 'evil\n' >"$CCODE_HOME/.local/bin/node"
    touch -d '2000-01-01' "$CCODE_HOME/.local/bin/node"
}
session forged_mtime
check "a change with a backdated mtime is still reported" reported ".local/bin/node"

remove_hook() { rm -f "$PROJECT/.git/hooks/post-checkout"; }
session remove_hook
check "a removed file is reported" reported ".git/hooks/post-checkout"

# --- audit log ----------------------------------------------------------------------------------
check "audit log written" [ -s "$AUDIT" ]
assert_eq "$(stat -c '%a' "$AUDIT")" 600 "audit log is 0600"
assert_eq "$(stat -c '%a' "$CONFIG_DIR/audit")" 700 "audit dir is 0700"
if command -v node >/dev/null 2>&1; then
    valid_jsonl() { node -e 'for (const l of require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n")) JSON.parse(l)' "$AUDIT"; }
    check "every audit record is valid JSON" valid_jsonl
fi
check "last report is retrievable" has_text '.git/hooks/post-checkout' "$(integrity_last_report)"

# Paths with quotes/backslashes stay valid JSON.
weird() { printf 'x\n' >"$PROJECT/.git/hooks/we\"ird\\name"; }
session weird
if command -v node >/dev/null 2>&1; then
    check "records with unusual paths stay valid JSON" valid_jsonl
fi

t_summary
