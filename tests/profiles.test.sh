#!/bin/bash
# Account profiles: layout migration with backup, profile selection, isolation
# of homes and secrets, the config overlay and its loosening guard, project
# binds, management commands and the shared skills/LSP exceptions. Runs the
# real bin/claude-dockerized against an isolated HOME/CONFIG_DIR with a fake
# `docker` first on PATH (no Docker needed). CCODE_HOME is NOT pinned here:
# that is what activates the profile layout.
#
# Threats: T-31 (cross-profile reads), T-32 (profile pin hijacked from the
# project), T-33 (a global secret overriding a profile's own login), T-34
# (a profile weakening the global posture) - see docs/security/THREAT-MODEL.md.
#
# Usage: bash tests/profiles.test.sh
# shellcheck disable=SC2317  # helpers run via check/gap

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="profiles"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
unset CCODE_HOME CLAUDE_DOCKERIZED_PROFILE SSH_AUTH_SOCK GNUPGHOME DRY_RUN
export CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC=1
export CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1
export NO_COLOR=1
PROJECT="$HOME/work/proj"
SUBDIR="$PROJECT/sub"
STUB="$TMP/stub"
CALLS="$TMP/calls"
mkdir -p "$SUBDIR" "$STUB" "$CALLS"

# Fake docker: records argv, answers info/image, `ps` reports a running
# session when DOCKER_STUB_PS is set, and `run` returns DOCKER_STUB_RUN_RC.
cat >"$STUB/docker" <<'EOF'
#!/bin/bash
n=$(find "$DOCKER_STUB_CALLS" -type f | wc -l)
printf '%s\n' "$@" >"$DOCKER_STUB_CALLS/$(printf '%04d' "$n")"
case "$1" in
info) exit 0 ;;
image) exit 0 ;;
ps) [ -n "${DOCKER_STUB_PS:-}" ] && echo abc123; exit 0 ;;
run) exit "${DOCKER_STUB_RUN_RC:-0}" ;;
*) exit 0 ;;
esac
EOF
chmod +x "$STUB/docker"
export DOCKER_STUB_CALLS="$CALLS"
export PATH="$STUB:$REPO_DIR/bin:$PATH"
WRAPPER="$REPO_DIR/bin/claude-dockerized"

# wrapper <args...> — runs from the project dir; sets OUT and RC.
wrapper() {
    rm -f "$CALLS"/*
    RC=0
    OUT="$(cd "$PROJECT" && "$WRAPPER" "$@" 2>&1)" || RC=$?
}
# wrapper_in <dir> <args...> — same, from another directory.
wrapper_in() {
    local dir="$1"
    shift
    rm -f "$CALLS"/*
    RC=0
    OUT="$(cd "$dir" && "$WRAPPER" "$@" 2>&1)" || RC=$?
}
last_run() {
    local f
    for f in $(find "$CALLS" -type f | sort -r); do
        if [ "$(head -n1 "$f")" = run ]; then
            cat "$f"
            return 0
        fi
    done
    return 1
}
ran_container() { last_run >/dev/null; }
argv_has() { has_line "$1" "$(last_run)"; }
argv_has_text() { has_text "$1" "$(last_run)"; }
argv_pair() {
    last_run | grep -xF -A1 -- "$1" | grep -qxF -- "$2"
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
P="$CONFIG_DIR/profiles"

# --- legacy single-account layout, as an existing install has it -------------
mkdir -p "$CONFIG_DIR/home/.claude" "$CONFIG_DIR/home/.local/share/claude" "$CONFIG_DIR/home/.cache/claude"
printf 'LEGACY-CREDENTIAL\n' >"$CONFIG_DIR/home/.claude/.credentials.json"
chmod 600 "$CONFIG_DIR/home/.claude/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"alice@example.com"}}\n' >"$CONFIG_DIR/home/.claude.json"
printf 'session\n' >"$CONFIG_DIR/home/.local/share/claude/session.jsonl"
printf 'cache\n' >"$CONFIG_DIR/home/.cache/claude/blob"
printf 'API_KEY=legacy\n' >"$CONFIG_DIR/env"
chmod 600 "$CONFIG_DIR/env"
printf 'setting.model=sonnet\nsetting.env_file=%s\n' "$CONFIG_DIR/env" >"$CONFIG_DIR/config"

# --- migration -----------------------------------------------------------------
wrapper profile migrate --dry-run
assert_eq "$RC" 0 "migrate --dry-run exits 0"
check "dry-run explains the plan" has_text "Would move" "$OUT"
check "dry-run moves nothing" [ -d "$CONFIG_DIR/home/.claude" ]
check_not "dry-run creates no default profile home" [ -e "$P/default/home" ]
check_not "dry-run takes no backup" [ -d "$CONFIG_DIR/backups" ]

wrapper profiles
assert_eq "$RC" 0 "profiles exits 0 (and migrates silently)"
check "the home moved into profiles/default/home" [ -s "$P/default/home/.claude/.credentials.json" ]
check_not "the legacy home is gone" [ -e "$CONFIG_DIR/home" ]
assert_eq "$(cat "$P/default/home/.claude/.credentials.json")" "LEGACY-CREDENTIAL" "credentials survive the move"
assert_eq "$(mode_of "$P/default/home/.claude/.credentials.json")" 600 "credentials keep mode 600"
check "sessions survive the move" [ -s "$P/default/home/.local/share/claude/session.jsonl" ]
check "the env file moved into the default profile" [ -s "$P/default/env" ]
assert_eq "$(mode_of "$P/default/env")" 600 "the moved env file is 0600"
check_not "no global env file is left behind" [ -e "$CONFIG_DIR/env" ]
check_not "setting.env_file is gone from the global config" grep -q 'env_file' "$CONFIG_DIR/config"
check "other global settings are kept" grep -qx 'setting.model=sonnet' "$CONFIG_DIR/config"
check "the migration says where the backup is" has_text "backup:" "$OUT"
BACKUP="$(find "$CONFIG_DIR/backups" -maxdepth 1 -type d -name 'pre-profiles-*' | head -n 1)"
check "a backup directory exists" [ -d "$BACKUP" ]
assert_eq "$(mode_of "$BACKUP")" 700 "the backup is private (0700)"
assert_eq "$(cat "$BACKUP/home/.claude/.credentials.json")" "LEGACY-CREDENTIAL" "the backup holds the credentials"
check "the backup holds the sessions" [ -s "$BACKUP/home/.local/share/claude/session.jsonl" ]
check "the backup holds the old config (with env_file)" grep -q 'env_file' "$BACKUP/config"
check "the backup holds the env file" [ -s "$BACKUP/env" ]
check "the list shows the account e-mail" has_text "alice@example.com" "$OUT"
check "the list shows the oauth login" has_text "oauth" "$OUT"
check "the list marks the active profile" has_text "* default" "$OUT"

wrapper profiles
assert_eq "$(find "$CONFIG_DIR/backups" -maxdepth 1 -type d -name 'pre-profiles-*' | wc -l | tr -d ' ')" 1 "the migration runs once (no second backup)"
check_not "no migration message on later runs" has_text "Migrated" "$OUT"

# --- default profile run: the migrated layout feeds the container --------------
wrapper run "$PROJECT"
assert_eq "$RC" 0 "run on the migrated default profile exits 0"
check "the default home is mounted" argv_has_text "$P/default/home/.claude:/home/coder/.claude:rw"
check "the default env file reaches docker" argv_pair --env-file "$P/default/env"
check "the profile name is passed to the container" argv_has "CLAUDE_DOCKERIZED_PROFILE=default"
check "sessions carry a profile label" argv_pair --label "claude-dockerized.profile=default"
check "the default model still applies" argv_pair --model sonnet
check_not "the legacy home path is not mounted" argv_has_text "$CONFIG_DIR/home/"

# --- create ---------------------------------------------------------------------
for bad in '../x' 'Work' 'a b' 'default' 'all' '-x' "$(printf 'a%.0s' $(seq 1 40))"; do
    wrapper profile create "$bad"
    check_not "create refuses the name '$bad'" [ "$RC" -eq 0 ]
done
check_not "no stray directory from refused names" [ -e "$HOME/.config/x" ]

printf 'ANTHROPIC_API_KEY=work-key\n' >"$TMP/work.env"
chmod 644 "$TMP/work.env"
wrapper profile create work --model haiku --env-file "$TMP/work.env"
assert_eq "$RC" 0 "create work exits 0"
check "create builds the home skeleton" [ -d "$P/work/home/.claude/hooks-guard" ]
assert_eq "$(mode_of "$P/work")" 700 "the profile directory is private"
assert_eq "$(mode_of "$P/work/env")" 600 "an imported env file becomes 0600"
check "the overlay records the model" grep -qx 'setting.model=haiku' "$P/work/config"
check "the new home gets the profile statusline" grep -q 'CLAUDE_DOCKERIZED_PROFILE' "$P/work/home/.claude/settings.json"
check_not "the new profile has no credentials" [ -s "$P/work/home/.claude/.credentials.json" ]
wrapper profile create work
check_not "create refuses an existing profile" [ "$RC" -eq 0 ]

# --- selection ---------------------------------------------------------------
wrapper run "$PROJECT" --profile work
assert_eq "$RC" 0 "run --profile work exits 0"
check "work's home is mounted" argv_has_text "$P/work/home/.claude:/home/coder/.claude:rw"
check_not "T-31: the default home is not mounted next to it" argv_has_text "$P/default/"
check "T-33: only the profile's own env file is passed" argv_pair --env-file "$P/work/env"
check_not "T-33: the other profile's env file is never passed" argv_pair --env-file "$P/default/env"
check "the profile model overrides the global one" argv_pair --model haiku
check "the profile name reaches the container" argv_has "CLAUDE_DOCKERIZED_PROFILE=work"
check "the container name carries the profile" argv_pair --name "$(last_run | grep -x 'claude-work-proj-.*' | head -n1)"
check "the banner names the profile" has_text "Profile: work" "$OUT"

wrapper run "$PROJECT" -p work
check "-p after run selects the profile" argv_has_text "$P/work/home/"
wrapper -p work run "$PROJECT"
check "-p as a global option selects the profile" argv_has_text "$P/work/home/"
wrapper run --profile=work "$PROJECT"
check "--profile=NAME selects the profile" argv_has_text "$P/work/home/"
CLAUDE_DOCKERIZED_PROFILE=work wrapper run "$PROJECT"
check "CLAUDE_DOCKERIZED_PROFILE selects the profile" argv_has_text "$P/work/home/"
CLAUDE_DOCKERIZED_PROFILE=work wrapper run "$PROJECT" --profile default
check "the flag beats the environment variable" argv_has_text "$P/default/home/"
wrapper run "$PROJECT" --profile nope
check_not "an unknown profile is refused" [ "$RC" -eq 0 ]
check_not "no container starts for an unknown profile" ran_container
check "the refusal says how to create it" has_text "profile create nope" "$OUT"
wrapper run "$PROJECT" --profile 'Bad Name'
check_not "an invalid name is refused" [ "$RC" -eq 0 ]
wrapper run "$PROJECT" -- --resume -p
check "arguments after -- are never read as the profile flag" argv_has --resume

# claude's own flags after -- must not be eaten
wrapper run "$PROJECT" --profile work -- --model opus
check "the claude model flag after -- passes through" argv_has opus

# exec / auth honour the profile too
wrapper exec "hi" --profile work
check "exec uses the profile home" argv_has_text "$P/work/home/.claude:/home/coder/.claude:rw"
wrapper profile login work
assert_eq "$RC" 0 "profile login exits 0"
check "login runs claude auth login" argv_has login
check "login uses the profile home" argv_has_text "$P/work/home/.claude:/home/coder/.claude:rw"

# --- use / bind (T-32) -----------------------------------------------------------
wrapper profile use work
assert_eq "$RC" 0 "profile use exits 0"
check "use writes setting.profile to the global config" grep -qx 'setting.profile=work' "$CONFIG_DIR/config"
wrapper profile current
check "current reports the configured profile" has_text "work (config)" "$OUT"
wrapper run "$PROJECT"
check "the configured profile is used without a flag" argv_has_text "$P/work/home/"
wrapper profile use default
wrapper profile current --name
assert_eq "$OUT" default "use default restores the default"

wrapper profile bind work "$PROJECT"
assert_eq "$RC" 0 "bind exits 0"
check "the bind lives in the config dir" [ -s "$CONFIG_DIR/profiles.map" ]
check_not "T-32: nothing is written inside the project" [ -e "$PROJECT/.ccd-profile" ]
wrapper run "$PROJECT"
check "a bound project uses its profile" argv_has_text "$P/work/home/"
wrapper_in "$SUBDIR" run "$SUBDIR"
check "a subdirectory inherits the bind" argv_has_text "$P/work/home/"
printf 'default\n' >"$PROJECT/.ccd-profile"
printf 'profile=default\n' >"$PROJECT/.claude-profile"
wrapper run "$PROJECT"
check "T-32: a file planted in the project cannot change the profile" argv_has_text "$P/work/home/"
rm -f "$PROJECT/.ccd-profile" "$PROJECT/.claude-profile"
wrapper run "$PROJECT" --profile default
check "an explicit flag still beats the bind" argv_has_text "$P/default/home/"
wrapper profile unbind "$PROJECT"
wrapper run "$PROJECT"
check "after unbind the project falls back to default" argv_has_text "$P/default/home/"
wrapper profile bind ghost "$PROJECT"
check_not "bind refuses a profile that does not exist" [ "$RC" -eq 0 ]

# --- overlay: tighten freely, loosen only with --allow-loosen (T-34) -------------
wrapper profile set work hardening strict
assert_eq "$RC" 0 "tightening needs no approval"
wrapper run "$PROJECT" --profile work
check "the tightened setting applies" argv_has "CLAUDE_DOCKERIZED_HARDENING=strict"

wrapper profile set work security_policy none
check_not "T-34: loosening the policy without approval is refused" [ "$RC" -eq 0 ]
check "the refusal names --allow-loosen" has_text "--allow-loosen" "$OUT"
check_not "nothing was written for the refused loosening" grep -q 'security_policy' "$P/work/config"
wrapper profile set work docker_socket true
check_not "T-34: enabling the docker socket without approval is refused" [ "$RC" -eq 0 ]
wrapper profile set work image_docker_cli false
check_not "settings that are not per-profile are refused" [ "$RC" -eq 0 ]
wrapper profile set work memory lots
check_not "invalid values are refused" [ "$RC" -eq 0 ]
wrapper profile set work ssh_agent_support maybe
check_not "invalid booleans are refused" [ "$RC" -eq 0 ]

# A hand-edited loosening without the approval marker is ignored, with a warning.
printf 'setting.security_policy=none\n' >>"$P/work/config"
wrapper run "$PROJECT" --profile work
check "T-34: an unapproved loosening in the overlay is dropped" argv_has "CLAUDE_DOCKERIZED_POLICY=balanced"
check "the dropped loosening is reported" has_text "without approval" "$OUT"
wrapper profile unset work security_policy

wrapper profile set work security_policy none --allow-loosen
assert_eq "$RC" 0 "an approved loosening is accepted"
check "the approval names the exact value" grep -qx 'allow_loosen.security_policy=none' "$P/work/config"
wrapper run "$PROJECT" --profile work
check "the approved loosening applies" argv_has "CLAUDE_DOCKERIZED_POLICY=none"
check "every run warns about the loosening" has_text "loosens the global security posture" "$OUT"
wrapper profiles
check "the list flags the loosening" has_text "loosens: security_policy" "$OUT"
wrapper profile doctor work
check "doctor reports the loosening" has_text "loosens security_policy" "$OUT"
wrapper profile set work security_policy strict
check "tightening again drops the approval marker" bash -c "! grep -q 'allow_loosen.security_policy' '$P/work/config'"
wrapper profile unset work security_policy
wrapper profile unset work hardening

# --- the guard sees what a session really gets (T-34) -------------------------------------------
cp "$CONFIG_DIR/config" "$TMP/global.bak"
wrapper profile create guard
# network: bridge is the global default; an overlay must not escape it
printf 'setting.hardening=strict\nsetting.memory=4g\nsetting.cpus=2\nsetting.security_policy=strict\n' >>"$CONFIG_DIR/config"
wrapper run "$PROJECT" --profile guard
check "baseline: the session runs on the default bridge network" argv_pair --network bridge
wrapper profile set guard network host
check_not "T-34: network=host over the bridge default is refused" [ "$RC" -eq 0 ]
printf 'setting.network=host\n' >>"$P/guard/config"
wrapper run "$PROJECT" --profile guard
check "T-34: a hand-edited network=host does not escape the bridge" argv_pair --network bridge
check "…and the drop is reported" has_text "loosens network" "$OUT"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'loosens network')" 1 "…once per run, not once per parse"
wrapper profile doctor guard
check_not "doctor fails on an ignored loosening" [ "$RC" -eq 0 ]
check "doctor names the ignored setting" has_text "tries to loosen network" "$OUT"
wrapper profile unset guard network
wrapper profile set guard network host --allow-loosen
assert_eq "$RC" 0 "an approved network=host is accepted"
wrapper run "$PROJECT" --profile guard
check "an approved network=host applies" argv_pair --network host
wrapper profiles
check "the list flags the approved network loosening" has_text "loosens: network" "$OUT"
wrapper profile unset guard network
# an approval names its value: changing the value voids it
wrapper profile set guard security_policy balanced --allow-loosen
wrapper run "$PROJECT" --profile guard
check "an approved value applies" argv_has "CLAUDE_DOCKERIZED_POLICY=balanced"
sed -i 's/^setting.security_policy=.*/setting.security_policy=none/' "$P/guard/config"
wrapper run "$PROJECT" --profile guard
check "T-34: editing the value after the approval voids it" argv_has "CLAUDE_DOCKERIZED_POLICY=strict"
wrapper profile unset guard security_policy
# resource limits
wrapper profile set guard memory 2g
assert_eq "$RC" 0 "a tighter memory limit needs no approval"
wrapper run "$PROJECT" --profile guard
check "the tighter limit applies" argv_pair --memory 2g
wrapper profile set guard memory 8g
check_not "T-34/T-23: a higher memory limit is refused" [ "$RC" -eq 0 ]
wrapper profile set guard memory 4096m
assert_eq "$RC" 0 "the same limit in other units is not a loosening"
wrapper profile set guard memory ""
check_not "T-34/T-23: dropping the memory limit is refused" [ "$RC" -eq 0 ]
wrapper profile set guard cpus 4
check_not "T-34/T-23: a higher cpu limit is refused" [ "$RC" -eq 0 ]
wrapper profile set guard cpus 1.5
assert_eq "$RC" 0 "a lower cpu limit is accepted"
printf 'setting.memory=\n' >>"$P/guard/config"
wrapper run "$PROJECT" --profile guard
check "a hand-edited memory removal is ignored (the global limit stays)" argv_pair --memory 4g
wrapper profile unset guard memory
wrapper profile set guard memory "" --allow-loosen
assert_eq "$RC" 0 "an approved memory removal is accepted"
wrapper run "$PROJECT" --profile guard
check_not "…and then no memory limit is passed" argv_has --memory
wrapper profile unset guard memory
wrapper profile unset guard cpus
# read-write mounts
mkdir -p "$HOME/data"
wrapper profile set guard "mount.d" "$HOME/data:/data:ro"
assert_eq "$RC" 0 "a read-only mount needs no approval"
wrapper run "$PROJECT" --profile guard
check "the read-only mount applies" argv_has_text ":/data:ro"
wrapper profile set guard "mount.d" "$HOME/data:/data:rw"
check_not "T-34: a read-write mount is refused without approval" [ "$RC" -eq 0 ]
printf 'mount.rw=%s/data:/rwdata:rw\n' "$HOME" >>"$P/guard/config"
wrapper run "$PROJECT" --profile guard
check_not "T-34: a hand-edited read-write mount is ignored" argv_has_text ":/rwdata"
check "…and reported" has_text "read-write mount" "$OUT"
wrapper profile unset guard mount.rw
wrapper profile set guard "mount.rw" "$HOME/data:/rwdata:rw" --allow-loosen
assert_eq "$RC" 0 "an approved read-write mount is accepted"
wrapper run "$PROJECT" --profile guard
check "the approved read-write mount applies" argv_has_text ":/rwdata:rw"
check "every run reports it" has_text "loosens the global security posture: mount.rw" "$OUT"
wrapper profile set guard "mount.rw" "$HOME/data:/elsewhere:rw"
check_not "a changed spec needs a new approval" [ "$RC" -eq 0 ]
wrapper profile set guard "mount.bad" "$HOME/data:relative"
check_not "an invalid mount spec is refused" [ "$RC" -eq 0 ]
wrapper profile set guard "mount.bad name" "$HOME/data:/x"
check_not "an invalid mount name is refused" [ "$RC" -eq 0 ]
wrapper profile unset guard mount.rw
wrapper profile unset guard mount.d
# profile edit checks the overlay on save the way `profile set` does
cat >"$TMP/editor-append" <<'EOF'
#!/bin/bash
cat "$EDITOR_APPEND" >>"$1"
EOF
chmod +x "$TMP/editor-append"
printf 'setting.model=opus\nmount.ro=%s/data:/ro-data:ro\n' "$HOME" >"$TMP/append-ok"
EDITOR="$TMP/editor-append" EDITOR_APPEND="$TMP/append-ok" wrapper profile edit guard
assert_eq "$RC" 0 "a clean overlay passes the edit check"
check "…and says so" has_text "no problems" "$OUT"
printf 'setting.memry=4g\nsetting.image_docker_cli=false\nsetting.cpus=lots\nmount.bad=%s/data:relative\nsetting.docker_socket=true\nstray line\n' "$HOME" >"$TMP/append-bad"
EDITOR="$TMP/editor-append" EDITOR_APPEND="$TMP/append-bad" wrapper profile edit guard
check_not "an overlay with problems fails the edit check" [ "$RC" -eq 0 ]
check "unknown setting reported" has_text "setting.memry cannot be overridden per profile" "$OUT"
check "global-only setting reported" has_text "setting.image_docker_cli cannot be overridden" "$OUT"
check "invalid value reported" has_text "setting.cpus:" "$OUT"
check "invalid mount reported" has_text "mount.bad:" "$OUT"
check "unapproved loosening reported" has_text "docker_socket loosens the global posture without approval" "$OUT"
check "stray line reported" has_text "unknown line 'stray line'" "$OUT"
: >"$P/guard/config"
# a profile drops a global mount with `-` (tightening, no approval)
printf 'mount.shared=%s/data:/shared:ro\n' "$HOME" >>"$CONFIG_DIR/config"
wrapper run "$PROJECT" --profile guard
check "baseline: the global mount reaches the session" argv_has_text ":/shared:ro"
wrapper profile set guard mount.shared -
assert_eq "$RC" 0 "dropping a global mount needs no approval"
wrapper run "$PROJECT" --profile guard
check_not "the dropped global mount is gone from this profile" argv_has_text ":/shared"
wrapper run "$PROJECT"
check "…and stays in the other profiles" argv_has_text ":/shared:ro"
printf 'mount.local=-\n' >>"$CONFIG_DIR/config"
wrapper config show
check "a '-' mount in the global config is ignored with a warning" has_text "only works in a profile overlay" "$OUT"
# profile rules are appended after the global session rules
printf 'Answer in Spanish.\n' >"$TMP/append-rules"
EDITOR="$TMP/editor-append" EDITOR_APPEND="$TMP/append-rules" wrapper profile edit guard rules
assert_eq "$RC" 0 "profile edit NAME rules works"
check "the rules file lives in the profile dir, outside the home" grep -q 'Answer in Spanish' "$P/guard/CLAUDE.md"
wrapper run "$PROJECT" --profile guard
rules="$(cat "$P/guard/home/.claude/CLAUDE.md")"
check "the global rules come first" [ "$(head -n1 "$P/guard/home/.claude/CLAUDE.md")" = "$(head -n1 "$CONFIG_DIR/CLAUDE.md")" ]
check "the profile rules follow under their header" has_text "## Profile rules (guard)" "$rules"
check "…with the profile's text" has_text "Answer in Spanish." "$rules"
wrapper run "$PROJECT"
check_not "other profiles do not get them" grep -q 'Answer in Spanish' "$P/default/home/.claude/CLAUDE.md"
check "the session still mounts the rules read-only" argv_has_text "/home/coder/.claude/CLAUDE.md:ro"
rm -f "$P/guard/CLAUDE.md"
wrapper run "$PROJECT" --profile guard
check_not "removing the rules file drops them on the next run" grep -q 'Profile rules' "$P/guard/home/.claude/CLAUDE.md"
# profile permissions add deny/ask rules to that profile's managed policy only
printf '# comment\ndeny WebFetch\nask Bash(npm publish *)\nallow Bash(rm -rf *)\ndeny Bad"Rule\n' >"$P/guard/permissions"
wrapper run "$PROJECT" --profile guard
managed="$P/guard/home/etc/claude-code/managed-settings.json"
check "the managed policy stays valid JSON" node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$managed"
perm_in() { node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).permissions;process.exit((p[process.argv[2]]||[]).includes(process.argv[3])?0:1)' "$managed" "$1" "$2"; }
check "a profile deny rule lands in permissions.deny" perm_in deny WebFetch
check "a profile ask rule lands in permissions.ask" perm_in ask "Bash(npm publish *)"
check "the global deny rules stay" perm_in deny "Read(./.env)"
check_not "an allow line is never merged" grep -q 'rm -rf \*)",$' <(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).permissions;console.log(JSON.stringify(p.allow||[]))' "$managed")
check "the allow line is reported" has_text "can only add restrictions" "$OUT"
check "a rule with a quote is refused" has_text "not a permission rule" "$OUT"
wrapper run "$PROJECT"
check_not "other profiles keep the global policy" grep -q '"WebFetch",' "$P/default/home/etc/claude-code/managed-settings.json"
rm -f "$P/guard/permissions"
wrapper run "$PROJECT" --profile guard
check_not "removing the file drops the rules on the next run" grep -q '"WebFetch",' "$managed"
# T-36: a profile's own guard allow rules apply only with an approval pinned to their content
global_allow="$CONFIG_DIR/hooks/policies/allow-patterns.json"
mirror_allow="$P/guard/home/.claude/hooks-guard/policies/allow-patterns.json"
printf '[{"id":"team-deploy","pattern":"^make deploy-staging$","reason":"team deploy target"}]\n' >"$P/guard/allow-patterns.json"
wrapper run "$PROJECT" --profile guard
check "T-36: unapproved profile allow rules are reported" has_text "not approved or changed since" "$OUT"
check "T-36: unapproved profile allow rules never reach the guard" cmp -s "$global_allow" "$mirror_allow"
wrapper profile approve guard allow-patterns </dev/null
check_not "T-36: approving without a terminal needs --yes" [ "$RC" -eq 0 ]
wrapper profile approve guard allow-patterns --yes
assert_eq "$RC" 0 "T-36: approve --yes pins the content"
check "the approval lists the rules it lets through" has_text "team-deploy" "$OUT"
check "the approval is a sha256 in the overlay" grep -qE '^allow_loosen\.allow_patterns=[0-9a-f]{64}$' "$P/guard/config"
wrapper run "$PROJECT" --profile guard
check "T-36: approved rules are merged after the global ones" grep -q '"team-deploy"' "$mirror_allow"
check "…the global rules stay" grep -q '"dotenv-example"' "$mirror_allow"
check "…and every run reports the loosening" has_text "loosens the global security posture: allow_patterns=" "$OUT"
eval_allow() { CGB_POLICIES_DIR="$(dirname "$mirror_allow")" CGB_CMD="make deploy-staging" CGB_POLICY_MODE=strict node "$REPO_DIR/hooks/guard-eval.js"; }
assert_eq "$(eval_allow)" allow "T-36: the guard evaluator loads the merged rules"
wrapper config sync --check
check_not "config sync --check accepts the approved merged mirror" has_text "allow-patterns.json mirror differs" "$OUT"
wrapper profile doctor guard
check "doctor names the approved allow rules" has_text "allow_patterns" "$OUT"
wrapper run "$PROJECT"
check_not "T-36: other profiles keep the global allow rules" grep -q '"team-deploy"' "$P/default/home/.claude/hooks-guard/policies/allow-patterns.json"
printf '[{"id":"team-deploy","pattern":".*","reason":"widened"}]\n' >"$P/guard/allow-patterns.json"
wrapper run "$PROJECT" --profile guard
check "T-36: editing the rules voids the approval" cmp -s "$global_allow" "$mirror_allow"
printf '[{"id":"bad","pattern":"(","reason":"x"}]\n' >"$P/guard/allow-patterns.json"
wrapper profile approve guard allow-patterns --yes
check_not "T-36: a pattern that does not compile is refused" [ "$RC" -eq 0 ]
printf '[{"id":"dotenv-example","pattern":"x","reason":"x"}]\n' >"$P/guard/allow-patterns.json"
wrapper profile approve guard allow-patterns --yes
check_not "T-36: a global id cannot be shadowed" [ "$RC" -eq 0 ]
rm -f "$P/guard/allow-patterns.json"
sed -i '/^allow_loosen\.allow_patterns=/d' "$P/guard/config"
# a profile can run its own Claude Code release in its own image
wrapper profile set guard claude_version 2.1.300
assert_eq "$RC" 0 "claude_version can be set per profile"
wrapper profile set guard claude_version latest
check_not "claude_version must be X.Y.Z" [ "$RC" -eq 0 ]
wrapper run "$PROJECT" --profile guard
check "the profile's sessions run its own image" argv_has "claude-dockerized:claude-2.1.300"
check_not "…not the shared one" argv_has "claude-dockerized:latest"
wrapper run "$PROJECT"
check "other profiles keep the shared image" argv_has "claude-dockerized:latest"
built_with() { grep -rqxF -- "$1" "$CALLS" 2>/dev/null; }
wrapper build --profile guard
assert_eq "$RC" 0 "build --profile builds the profile's image"
check "…tagged per version" built_with "claude-dockerized:claude-2.1.300"
check "…with that Claude release" built_with "CLAUDE_CODE_VERSION=2.1.300"
wrapper profile show guard
check "profile show names the session image" has_text "Claude Code image: claude-dockerized:claude-2.1.300 [profile]" "$OUT"
wrapper profile unset guard claude_version
# profile show says where each value comes from
wrapper profile set guard model opus
printf 'setting.docker_socket=true\n' >>"$P/guard/config"
wrapper profile show guard
check "an overlay value is marked [profile]" has_text "Model: opus [profile]" "$OUT"
check "a dropped loosening is marked as the global value" has_text "Docker socket: false [global; profile value dropped]" "$OUT"
check "a global value carries no marker" has_line "  Security policy: strict" "$OUT"
check "a dropped global mount is listed" has_text "mount.shared dropped by this profile" "$OUT"
check "the legend names the overlay file" has_text "[profile] = $P/guard/config" "$OUT"
wrapper profile unset guard mount.shared
cp "$TMP/global.bak" "$CONFIG_DIR/config"
wrapper profile delete guard --yes

# --- shared skills and LSP binaries (read-only exceptions) -----------------------
wrapper profile set work share_skills true
check_not "T-31: sharing the default profile's skills needs approval" [ "$RC" -eq 0 ]
wrapper profile set work lsp_from default
check_not "T-31: reading the default profile's binaries needs approval" [ "$RC" -eq 0 ]
printf 'setting.share_skills=true\nsetting.lsp_from=default\n' >>"$P/work/config"
wrapper run "$PROJECT" --profile work
check_not "T-31: hand-edited sharing without approval is ignored" argv_has_text "$P/default/"
wrapper profile unset work share_skills
wrapper profile unset work lsp_from
wrapper profile set work share_skills true --allow-loosen
assert_eq "$RC" 0 "approved share_skills is accepted"
wrapper profile set work lsp_from default --allow-loosen
assert_eq "$RC" 0 "approved lsp_from is accepted"
wrapper run "$PROJECT" --profile work
check "shared skills come from the default profile, read-only" argv_has_text "$P/default/home/.claude/skills:/home/coder/.claude/skills:ro"
check_not "the profile's own skills are not mounted when shared" argv_has_text "$P/work/home/.claude/skills:"
check "shared LSP binaries come from the default profile, read-only" argv_has_text "$P/default/home/.local/bin:/home/coder/.local/bin:ro"
default_private_mounted() {
    last_run | grep -qE "$P/default/home/(\.claude:|\.claude\.json|\.local/share|\.mcp-auth)"
}
check_not "T-31: nothing else of the default profile is mounted" default_private_mounted
wrapper profile unset work share_skills
wrapper profile unset work lsp_from
wrapper run "$PROJECT" --profile work
check_not "T-31: without sharing no default path is mounted" argv_has_text "$P/default/"

# create --share-skills / --lsp-from are the explicit request, so they carry their approval
wrapper profile create sharer --share-skills --lsp-from default
assert_eq "$RC" 0 "create --share-skills --lsp-from exits 0"
wrapper run "$PROJECT" --profile sharer
check "create --share-skills takes effect without a second step" argv_has_text "$P/default/home/.claude/skills:/home/coder/.claude/skills:ro"
check "create --lsp-from takes effect without a second step" argv_has_text "$P/default/home/.local/bin:/home/coder/.local/bin:ro"
wrapper profile delete sharer --yes

# --- list / show / path ------------------------------------------------------------
wrapper profile list --json
if command -v node >/dev/null 2>&1; then
    json_ok() { printf '%s' "$OUT" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(j.profiles.length===2&&j.active==="default"?0:1)'; }
    check "list --json is valid JSON with both profiles" json_ok
fi
wrapper profiles
check "list names every profile" has_text "work" "$OUT"
check "list shows the profile model" has_text "haiku" "$OUT"
wrapper profile show work
check "show prints the profile directory" has_text "$P/work" "$OUT"
check "show never prints secret values" bash -c "! grep -q 'work-key' <<<'$OUT'"
wrapper profile path work env
assert_eq "$OUT" "$P/work/env" "path env"

# --- logout / rename / delete ---------------------------------------------------------
wrapper profile logout default
check_not "logout without a terminal needs --yes" [ "$RC" -eq 0 ]
check "the credentials were not touched" [ -s "$P/default/home/.claude/.credentials.json" ]
wrapper profile logout default --yes
assert_eq "$RC" 0 "logout --yes exits 0"
check_not "logout empties the credentials" [ -s "$P/default/home/.claude/.credentials.json" ]
assert_eq "$(mode_of "$P/default/home/.claude/.credentials.json")" 600 "emptied credentials stay 0600"

wrapper profile bind work "$PROJECT"
DOCKER_STUB_PS=1 wrapper profile rename work job
check_not "rename refuses a profile with a running session" [ "$RC" -eq 0 ]
wrapper profile rename work job
assert_eq "$RC" 0 "rename exits 0"
check "rename moves the directory" [ -d "$P/job/home" ]
check_not "the old directory is gone" [ -e "$P/work" ]
wrapper run "$PROJECT"
check "rename repoints the project bind" argv_has_text "$P/job/home/"
wrapper profile rename default x
check_not "the default profile cannot be renamed" [ "$RC" -eq 0 ]

wrapper profile delete job
check_not "delete without a terminal needs --yes" [ "$RC" -eq 0 ]
DOCKER_STUB_PS=1 wrapper profile delete job --yes
check_not "delete refuses a profile with a running session" [ "$RC" -eq 0 ]
check "the running profile was kept" [ -d "$P/job" ]
wrapper profile delete job --yes
assert_eq "$RC" 0 "delete --yes exits 0"
check_not "delete removes the profile" [ -e "$P/job" ]
check_not "delete drops the project bind" [ -s "$CONFIG_DIR/profiles.map" ]
wrapper profile delete default --yes
check_not "deleting the default profile needs --force" [ "$RC" -eq 0 ]

# --- doctor / sync ------------------------------------------------------------------------
wrapper profile create extra
chmod 644 "$P/extra/home/.claude/settings.json" 2>/dev/null
printf 'K=v\n' >"$P/extra/env"
chmod 644 "$P/extra/env"
wrapper profile doctor extra
check_not "doctor fails on a group-readable env file" [ "$RC" -eq 0 ]
check "doctor says how to fix it" has_text "chmod 600" "$OUT"
chmod 600 "$P/extra/env"
wrapper config sync --check
check "config sync visits every profile" has_text "Profile: extra" "$OUT"
rm -f "$P/extra/home/.claude/hooks-guard/claude-guard-bash.sh"
wrapper config sync --check
check_not "sync --check flags drift in an idle profile" [ "$RC" -eq 0 ]
wrapper config sync
wrapper config sync --check
assert_eq "$RC" 0 "config sync repairs the idle profile"
wrapper profile delete extra --yes

# --- pinned CCODE_HOME disables profiles -----------------------------------------------------
CCODE_HOME="$TMP/pinned-home" wrapper run "$PROJECT" --profile work
check_not "a pinned CCODE_HOME refuses --profile" [ "$RC" -eq 0 ]
check "the refusal explains the pin" has_text "pins the state root" "$OUT"

# --- rollback to the single-account layout ------------------------------------------------------
wrapper profile migrate --rollback
assert_eq "$RC" 0 "rollback exits 0 when only the default profile is left"
check "rollback restores the legacy home" [ -d "$CONFIG_DIR/home/.claude" ]
check "rollback restores the sessions" [ -s "$CONFIG_DIR/home/.local/share/claude/session.jsonl" ]
check "rollback restores the env file where it was" [ -s "$CONFIG_DIR/env" ]
check "rollback restores the old config" grep -q "env_file=$CONFIG_DIR/env" "$CONFIG_DIR/config"
check_not "rollback leaves no profiles directory" [ -e "$P" ]
wrapper profiles
check "the next run migrates again" [ -s "$P/default/env" ]

# --- fixtures for the robustness cases below ------------------------------------------
make_legacy() {
    rm -rf "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR/home/.claude"
    printf 'LEGACY-CREDENTIAL\n' >"$CONFIG_DIR/home/.claude/.credentials.json"
    chmod 600 "$CONFIG_DIR/home/.claude/.credentials.json"
    printf 'API_KEY=legacy\n' >"$CONFIG_DIR/env"
    chmod 600 "$CONFIG_DIR/env"
    printf 'setting.model=sonnet\nsetting.env_file=%s\n' "$CONFIG_DIR/env" >"$CONFIG_DIR/config"
}

# --- rollback keeps what the user changed since the migration --------------------------
make_legacy
wrapper profiles
printf 'setting.memory=2g\n' >>"$CONFIG_DIR/config"
wrapper profile use default
wrapper profile migrate --rollback
assert_eq "$RC" 0 "rollback exits 0"
check "rollback keeps settings added after the migration" grep -qx 'setting.memory=2g' "$CONFIG_DIR/config"
check "rollback keeps the other global settings" grep -qx 'setting.model=sonnet' "$CONFIG_DIR/config"
check "rollback restores setting.env_file" grep -qx "setting.env_file=$CONFIG_DIR/env" "$CONFIG_DIR/config"
check_not "rollback drops setting.profile" grep -q 'setting.profile' "$CONFIG_DIR/config"
check "rollback says to use the previous version" has_text "previous wrapper version" "$OUT"

# --- the wrapper rollback must not strand the account ------------------------------------
make_legacy
wrapper profiles
mkdir -p "$TMP/state"
printf 'abc123\n' >"$TMP/state/last-good"
rollback_precheck() {
    RC=0
    OUT="$(
        (
            source "$REPO_DIR/lib/config-lib.sh"
            UPDATE_STATE_DIR="$TMP/state"
            _update_git() { [ "${FAKE_HAS_LAYOUT:-}" = yes ]; }
            PROFILE_FLAG=default
            activate_profile
            profile_rollback_precheck
            rc=$?
            echo "layout=$PROFILE_ROLLBACK_LAYOUT"
            exit "$rc"
        ) 2>&1
    )" || RC=$?
}
FAKE_HAS_LAYOUT=yes rollback_precheck
assert_eq "$RC" 0 "a rollback target that knows profiles needs nothing"
check "…and the layout is left alone" has_text "layout=false" "$OUT"
FAKE_HAS_LAYOUT=no rollback_precheck
assert_eq "$RC" 0 "a target that predates profiles is accepted while only default exists"
check "…and the layout is reverted after the checkout" has_text "layout=true" "$OUT"
wrapper profile create zz
FAKE_HAS_LAYOUT=no rollback_precheck
check_not "a target that predates profiles is refused while other profiles exist" [ "$RC" -eq 0 ]
check "…naming the profiles it would hide" has_text "zz" "$OUT"
wrapper profile delete zz --yes
wrapper profile migrate --prune-backups
check_not "pruning the backups needs --yes without a terminal" [ "$RC" -eq 0 ]
wrapper profile migrate --prune-backups --yes
assert_eq "$RC" 0 "prune --yes exits 0"
check_not "the backups are gone" [ -d "$CONFIG_DIR/backups" ]
FAKE_HAS_LAYOUT=no rollback_precheck
check_not "without a backup the layout cannot be reverted, so the rollback is refused" [ "$RC" -eq 0 ]
wrapper profile logout default --yes
check_not "no backup left, so logout has nothing to warn about" has_text "Migration backups" "$OUT"

# --- a backup that fails blocks the migration and says why ---------------------------------
make_legacy
: >"$CONFIG_DIR/backups" # a file where the backup directory should go
wrapper profiles
check_not "a failing backup stops the command" [ "$RC" -eq 0 ]
check "the cause is shown" has_text "Cannot create the backup directory" "$OUT"
check "the way out is shown" has_text "--no-backup" "$OUT"
check "nothing was moved" [ -s "$CONFIG_DIR/home/.claude/.credentials.json" ]
check_not "no empty default profile was created behind the user's back" [ -e "$P/default/home" ]
rm -f "$CONFIG_DIR/backups"
wrapper profile migrate --no-backup
assert_eq "$RC" 0 "migrate --no-backup exits 0"
check "it warns that no data copy is kept" has_text "without a backup copy" "$OUT"
check "the account moved" [ -s "$P/default/home/.claude/.credentials.json" ]
NB_REC="$(find "$CONFIG_DIR/backups" -maxdepth 1 -type d -name 'pre-profiles-*' | head -n 1)"
check "a record for rollback is still written" [ -f "$NB_REC/MANIFEST" ]
check_not "…but no copy of the home was taken" [ -e "$NB_REC/home" ]
wrapper profile migrate --rollback
assert_eq "$RC" 0 "rollback works from the record even without a data copy"
check "…and restores the home" [ -s "$CONFIG_DIR/home/.claude/.credentials.json" ]

# --- an env file that lived inside the old home --------------------------------------------
make_legacy
mv "$CONFIG_DIR/env" "$CONFIG_DIR/home/.claude/secret.env"
printf 'setting.env_file=%s\n' "$CONFIG_DIR/home/.claude/secret.env" >"$CONFIG_DIR/config"
wrapper profiles
assert_eq "$RC" 0 "migration with an env file inside the home exits 0"
check "the env file ends up outside the profile home" [ -s "$P/default/env" ]
check_not "…and no longer inside it" [ -e "$P/default/home/.claude/secret.env" ]
check_not "setting.env_file is gone from the config" grep -q env_file "$CONFIG_DIR/config"
check_not "no error from the move" has_text "cannot stat" "$OUT"
wrapper profile migrate --rollback
check "rollback puts it back where it was" [ -s "$CONFIG_DIR/home/.claude/secret.env" ]

# --- a first run waits for a running migration ---------------------------------------------
make_legacy
mkdir "$CONFIG_DIR/.profiles-migrate.lock"
(sleep 1 && rmdir "$CONFIG_DIR/.profiles-migrate.lock") &
wrapper profiles
wait
assert_eq "$RC" 0 "a run that finds the migration lock waits and then succeeds"
check "…and the account is migrated" [ -s "$P/default/home/.claude/.credentials.json" ]

# --- the account e-mail comes from oauthAccount only (with and without node) -------------------
email_probe() { # <json> [nonode]
    printf '%s\n' "$1" >"$TMP/email-home.json"
    mkdir -p "$TMP/email-home" && cp "$TMP/email-home.json" "$TMP/email-home/.claude.json"
    (
        source "$REPO_DIR/lib/config-lib.sh"
        if [ "${2:-}" = nonode ]; then
            command() { [ "${2:-}" = node ] && return 1; builtin command "$@"; }
        fi
        profile_account_email "$TMP/email-home"
    )
}
for mode in node nonode; do
    assert_eq "$(email_probe '{"oauthAccount":{"emailAddress":"a@b.io"}}' "$mode")" "a@b.io" "e-mail read from oauthAccount ($mode)"
    assert_eq "$(email_probe "$(printf '{\n "oauthAccount": {\n  "accountUuid": "u",\n  "emailAddress": "multi@line.io"\n }\n}')" "$mode")" "multi@line.io" "pretty-printed oauthAccount ($mode)"
    assert_eq "$(email_probe '{"emailAddress":"top@level.io","mcpServers":{"x":{"emailAddress":"srv@x.io"}}}' "$mode")" "" "an emailAddress outside oauthAccount is not the account ($mode)"
    assert_eq "$(email_probe '{"oauthAccount":{"emailAddress":"bad one@x.io"}}' "$mode")" "" "an e-mail with odd characters is dropped ($mode)"
    assert_eq "$(email_probe '{"oauthAccount":null,"x":{"emailAddress":"bad@x.com"}}' "$mode")" "" "oauthAccount: null does not borrow another object's e-mail ($mode)"
done

# --- a failed create leaves nothing behind ------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    : >"$TMP/unreadable.env"
    chmod 000 "$TMP/unreadable.env"
    wrapper profile create broken --env-file "$TMP/unreadable.env"
    check_not "create fails when the env file cannot be read" [ "$RC" -eq 0 ]
    check_not "the half-built profile is removed" [ -e "$P/broken" ]
    chmod 600 "$TMP/unreadable.env"
    wrapper profile create broken --env-file "$TMP/unreadable.env"
    assert_eq "$RC" 0 "the same name can be created again afterwards"
    wrapper profile delete broken --yes
fi

# --- bash completion offers real profile names only ---------------------------------------------
complete_profiles() {
    HOME="$TMP/comp-home" CONFIG_DIR="$TMP/comp-home/cfg" bash -c '
        source "$1/completions/bash.sh"
        COMP_WORDS=(ccd run x --profile ""); COMP_CWORD=4
        _claude_dockerized
        printf "%s\n" "${COMPREPLY[@]}"' _ "$REPO_DIR"
}
mkdir -p "$TMP/comp-home/cfg/profiles"
assert_eq "$(complete_profiles)" "default" "an empty profiles directory offers only default (no literal glob)"
mkdir -p "$TMP/comp-home/cfg/profiles/alpha" "$TMP/comp-home/cfg/profiles/beta" "$TMP/comp-home/cfg/profiles/default" "$TMP/comp-home/cfg/profiles/Bad Name"
assert_eq "$(complete_profiles | paste -sd' ' -)" "default alpha beta" "existing profiles are offered once, invalid directory names never"

# --- create leaves nothing behind on any failure, and --from reports copy errors ----------------------
failing_create() (
    source "$REPO_DIR/lib/config-lib.sh"
    PROFILE_FLAG=default
    activate_profile
    ensure_claude_dirs() { return 1; }
    profile_cmd_create zzfail
)
failing_create >/dev/null 2>&1
check_not "create fails when the home cannot be built" [ "$?" -eq 0 ]
check_not "…and the half-built profile is removed" [ -e "$P/zzfail" ]
if [ "$(id -u)" -ne 0 ]; then
    wrapper profile create e1
    printf '{}\n' >"$P/e1/home/.claude/settings.json"
    chmod 000 "$P/e1/home/.claude/settings.json"
    wrapper profile create e2 --from e1
    check_not "create --from fails when a preference file cannot be copied" [ "$RC" -eq 0 ]
    check_not "…and keeps nothing" [ -e "$P/e2" ]
    chmod 600 "$P/e1/home/.claude/settings.json"
    wrapper profile delete e1 --yes
fi

# --- a pinned CCODE_HOME ignores a configured default and binds instead of failing every command ------
printf 'setting.profile=whatever\n' >>"$CONFIG_DIR/config"
CCODE_HOME="$TMP/pinned-home2" wrapper config show
assert_eq "$RC" 0 "a pinned CCODE_HOME does not fail on a configured default profile"
CCODE_HOME="$TMP/pinned-home2" wrapper profile current
check "…it just reports the pin" has_text "default (pinned)" "$OUT"
profile_file_unset_cfg() ( source "$REPO_DIR/lib/config-lib.sh"; profile_file_unset "$CONFIG_FILE" setting.profile )
profile_file_unset_cfg

# --- resource limits: zero and absurd values are "no limit" (T-23/T-34) -------------------------
make_legacy
wrapper profiles
wrapper profile create lim
printf 'setting.memory=4g\nsetting.cpus=2\n' >>"$CONFIG_DIR/config"
for v in 0g 0m 0b 0 99999999999999999999g 8589934592g 17179869184g; do
    wrapper profile set lim memory "$v"
    check_not "memory $v is refused" [ "$RC" -eq 0 ]
done
for v in 0 0.0 00 3; do
    wrapper profile set lim cpus "$v"
    check_not "cpus $v is refused" [ "$RC" -eq 0 ]
done
printf 'setting.memory=0g\nsetting.cpus=0\n' >>"$P/lim/config"
wrapper run "$PROJECT" --profile lim
check "a hand-edited memory=0g does not lift the limit" argv_pair --memory 4g
check "a hand-edited cpus=0 does not lift the limit" argv_pair --cpus 2
wrapper profiles
check "list shows what the overlay tried and was ignored" has_text "ignored (unapproved): memory,cpus" "$OUT"
wrapper profile list --json
if command -v node >/dev/null 2>&1; then
    ignored_ok() { printf '%s' "$OUT" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));const p=j.profiles.find(x=>x.name==="lim");process.exit(p.ignored.includes("memory")?0:1)'; }
    check "list --json reports the ignored settings" ignored_ok
fi
: >"$P/lim/config"

# --- a line break in a value cannot smuggle settings (or approvals) in ------------------------------
mkdir -p "$HOME/data"
printf 'setting.model=haiku\n' >"$P/lim/config"
before_cfg="$(cat "$P/lim/config")"
wrapper profile set lim mount.x "$HOME/data:/x:ro"$'\n'"setting.security_policy=none"$'\n'"allow_loosen.security_policy=none"
check_not "T-34: a mount value with line breaks is refused" [ "$RC" -eq 0 ]
assert_eq "$(cat "$P/lim/config")" "$before_cfg" "T-34: …and the overlay is untouched"
wrapper profile set lim model $'haiku\nsetting.hardening=off'
check_not "a model value with a line break is refused" [ "$RC" -eq 0 ]
assert_eq "$(cat "$P/lim/config")" "$before_cfg" "…and the overlay is untouched again"
set_with_break() (
    source "$REPO_DIR/lib/config-lib.sh"
    profile_file_set "$TMP/ini" setting.x $'a\nb'
)
check_not "profile_file_set itself refuses a line break" set_with_break

# --- an empty network value must not end the command silently ---------------------------------------
wrapper profile set lim network ""
assert_eq "$RC" 0 "an empty network value can be set"
wrapper run "$PROJECT" --profile lim
assert_eq "$RC" 0 "…and the run still works (no silent exit)"
wrapper profile unset lim network

# --- hand-edited, indented lines are found by set/unset like the loader finds them ------------------
printf '  setting.model = opus\n\tsetting.cpus =1\n' >"$P/lim/config"
wrapper profile unset lim model
check_not "unset removes an indented line" grep -q 'model' "$P/lim/config"
wrapper profile set lim cpus 1
assert_eq "$(grep -c 'cpus' "$P/lim/config")" 1 "set replaces the indented line instead of adding another"
: >"$P/lim/config"

# --- an approved hardening change no longer moves the network ------------------------------------------
printf 'setting.hardening=strict\n' >>"$CONFIG_DIR/config"
wrapper profile set lim hardening standard --allow-loosen
wrapper profiles
check "only hardening is listed as loosened" has_text "loosens: hardening" "$OUT"
check_not "…the network is not" has_text "loosens: hardening,network" "$OUT"
wrapper run "$PROJECT" --profile lim
check "…and the session stays on the bridge network" argv_pair --network bridge
wrapper profile delete lim --yes

# --- the wrapper-rollback precheck agrees with --rollback --------------------------------------------------
make_legacy
wrapper profiles
mkdir "$CONFIG_DIR/home"
FAKE_HAS_LAYOUT=no rollback_precheck
check_not "precheck refuses when the old home already exists" [ "$RC" -eq 0 ]
rmdir "$CONFIG_DIR/home"
mkdir "$CONFIG_DIR/backups/pre-profiles-99999999T999999Z-1" # an interrupted backup: no record
FAKE_HAS_LAYOUT=no rollback_precheck
assert_eq "$RC" 0 "an interrupted newer backup is skipped in favour of the complete one"
find "$CONFIG_DIR/backups" -mindepth 2 -maxdepth 2 -name MANIFEST -delete
FAKE_HAS_LAYOUT=no rollback_precheck
check_not "with only an interrupted backup left, the rollback is refused up front" [ "$RC" -eq 0 ]
check "…and nothing was moved" [ -d "$P/default/home" ]

# --- rollback never deletes or overwrites what the old layout cannot hold ---------------------------------
make_legacy
wrapper profiles
printf 'setting.model=opus\n' >"$P/default/config"
wrapper profile migrate --rollback
assert_eq "$RC" 0 "rollback with a default overlay exits 0"
check "the default overlay is kept" [ -s "$P/default/config" ]
check "…with a warning" has_text "overlay stays" "$OUT"
check "the home is back" [ -s "$CONFIG_DIR/home/.claude/.credentials.json" ]
make_legacy
wrapper profiles
printf 'ALREADY-THERE\n' >"$CONFIG_DIR/env"
wrapper profile migrate --rollback
assert_eq "$(cat "$CONFIG_DIR/env")" "ALREADY-THERE" "rollback does not overwrite an existing file at the old env path"
check "the profile env file is kept and reported" has_text "was left in place" "$OUT"
check "…still present" [ -s "$P/default/env" ]
make_legacy
rm -f "$CONFIG_DIR/env"
printf 'setting.model=sonnet\n' >"$CONFIG_DIR/config"
wrapper profiles
printf 'K=v\n' >"$P/default/env"
chmod 600 "$P/default/env"
wrapper profile migrate --rollback
check "an env file created after the migration is kept and reported" has_text "was left in place" "$OUT"
check "…and the home is back" [ -d "$CONFIG_DIR/home/.claude" ]

# --- backups: the copy is checked, names never collide, an interrupted one is harmless ---------------------
if [ "$(id -u)" -ne 0 ]; then
    make_legacy
    chmod 000 "$CONFIG_DIR/env"
    wrapper profiles
    check_not "a backup that cannot copy the env file stops the migration" [ "$RC" -eq 0 ]
    check "…saying which part failed" has_text "Backup of the env file failed" "$OUT"
    check "…with the home untouched" [ -s "$CONFIG_DIR/home/.claude/.credentials.json" ]
    half_backup() { [ -d "$CONFIG_DIR/backups" ] && find "$CONFIG_DIR/backups" -mindepth 1 | grep -q .; }
    check_not "…and no half backup left behind" half_backup
    chmod 600 "$CONFIG_DIR/env"
fi
make_legacy
wrapper profiles
wrapper profile migrate --rollback
wrapper profiles
assert_eq "$RC" 0 "migrate, rollback and migrate again in the same second works"
assert_eq "$(find "$CONFIG_DIR/backups" -maxdepth 1 -type d -name 'pre-profiles-*' | wc -l | tr -d ' ')" 2 "…and keeps two distinct backups"
wrapper profile migrate --yes --prune-backups
assert_eq "$RC" 0 "--yes may come before --prune-backups"

# --- the migration lock: stale locks are cleared, the lock is always released ---------------------------------
make_legacy
sleep 0 &
dead_pid=$!
wait "$dead_pid"
mkdir "$CONFIG_DIR/.profiles-migrate.lock"
printf '%s\n' "$dead_pid" >"$CONFIG_DIR/.profiles-migrate.lock/pid"
start=$SECONDS
wrapper profiles
assert_eq "$RC" 0 "a lock whose owner is gone does not block"
check "…and does not make the command wait" [ $((SECONDS - start)) -lt 8 ]
check "…the account is migrated" [ -s "$P/default/home/.claude/.credentials.json" ]
check_not "…and no lock is left" [ -e "$CONFIG_DIR/.profiles-migrate.lock" ]
make_legacy
mkdir "$CONFIG_DIR/.profiles-migrate.lock"
touch -d '2 minutes ago' "$CONFIG_DIR/.profiles-migrate.lock"
wrapper profiles
assert_eq "$RC" 0 "an old lock with no owner recorded is cleared too"
if [ "$(id -u)" -ne 0 ]; then
    make_legacy
    chmod 444 "$CONFIG_DIR/config"
    wrapper profile migrate
    check "a config that cannot be rewritten only warns" has_text "Could not drop setting.env_file" "$OUT"
    check_not "T-31: the lock is released even then" [ -e "$CONFIG_DIR/.profiles-migrate.lock" ]
    chmod 644 "$CONFIG_DIR/config"
fi

# --- lock ownership: a release never removes somebody else's lock --------------------------------------------
lock_unit() ( # <snippet run after sourcing the lib>
    source "$REPO_DIR/lib/config-lib.sh"
    eval "$1"
)
make_legacy
mkdir "$CONFIG_DIR/.profiles-migrate.lock"
printf '424242\n' >"$CONFIG_DIR/.profiles-migrate.lock/pid"
lock_unit '_profile_lock_release'
check "a release by a process that does not own the lock leaves it alone" [ -d "$CONFIG_DIR/.profiles-migrate.lock" ]
rm -rf "${CONFIG_DIR:?}/.profiles-migrate.lock"
lock_unit '_profile_lock_acquire && _profile_lock_release'
check_not "the owner's release removes the lock" [ -e "$CONFIG_DIR/.profiles-migrate.lock" ]
sleep 0 &
dead2=$!
wait "$dead2"
mkdir "$CONFIG_DIR/.profiles-migrate.lock"
printf '%s\n' "$dead2" >"$CONFIG_DIR/.profiles-migrate.lock/pid"
lock_unit '_profile_lock_acquire'
assert_eq "$(cat "$CONFIG_DIR/.profiles-migrate.lock/pid")" "$$" "taking over a stale lock records the new owner"
check_not "…and leaves no moved-aside copy behind" compgen -G "$CONFIG_DIR/.profiles-migrate.lock.stale.*"
rm -rf "${CONFIG_DIR:?}/.profiles-migrate.lock"

# --- --dry-run / --no-backup do not apply to the other actions -----------------------------------------------
make_legacy
wrapper profiles
wrapper profile migrate --rollback --dry-run
check_not "--rollback --dry-run is refused instead of rolling back for real" [ "$RC" -eq 0 ]
check "…and nothing moved" [ -d "$P/default/home" ]
wrapper profile migrate --prune-backups --no-backup --yes
check_not "--prune-backups --no-backup is refused" [ "$RC" -eq 0 ]
check "…and the backups are still there" [ -d "$CONFIG_DIR/backups" ]

# --- the backup skips .cache, and --no-backup does not claim a backup -----------------------------------------
make_legacy
mkdir -p "$CONFIG_DIR/home/.cache/claude"
printf 'big\n' >"$CONFIG_DIR/home/.cache/claude/blob"
wrapper profiles
CACHE_BACKUP="$(find "$CONFIG_DIR/backups" -maxdepth 1 -type d -name 'pre-profiles-*' | head -n 1)"
check "the backup holds the credentials" [ -s "$CACHE_BACKUP/home/.claude/.credentials.json" ]
check_not "…but not the cache" [ -e "$CACHE_BACKUP/home/.cache" ]
check "the live profile keeps its cache" [ -s "$P/default/home/.cache/claude/blob" ]
make_legacy
wrapper profile migrate --no-backup
check "--no-backup says it kept only a rollback record" has_text "no data backup; rollback record" "$OUT"
check_not "…and does not say 'backup:'" has_text "(backup:" "$OUT"

# --- a pinned CCODE_HOME lists only the default profile and does not fail ----------------------------------------
mkdir -p "$P/extra-dir"
CCODE_HOME="$TMP/pinned-home3" wrapper profiles
assert_eq "$RC" 0 "profiles under a pinned CCODE_HOME exits 0 even with other profile directories around"
check_not "…and lists only default" has_text "extra-dir" "$OUT"
rm -rf "${P:?}/extra-dir"

# --- config show reports the network the session really gets ------------------------------------------------------
cp "$CONFIG_DIR/config" "$TMP/global2.bak"
printf 'setting.hardening=strict\n' >>"$CONFIG_DIR/config"
wrapper config show
check "config show reports the bridge network" has_text "Container network: bridge" "$OUT"
cp "$TMP/global2.bak" "$CONFIG_DIR/config"

# --- env placement during the migration ----------------------------------------------------------------------
make_legacy
mkdir -p "$P/default"
printf 'OLD-DEFAULT\n' >"$P/default/env"
chmod 600 "$P/default/env"
wrapper profile migrate
assert_eq "$RC" 0 "migration with an existing default env file exits 0"
assert_eq "$(cat "$P/default/env")" "OLD-DEFAULT" "an existing profile env file is never overwritten"
check "the legacy env file stays where it was" [ -s "$CONFIG_DIR/env" ]
check "setting.env_file stays until the files are merged" grep -q env_file "$CONFIG_DIR/config"
check "the user is told" has_text "already exists" "$OUT"

# --- a stale setting.profile must not lock the user out ----------------------------------------
wrapper profile create gone
wrapper profile use gone
rm -rf "${P:?}/gone"
for stale_cmd in "profiles" "config path" "doctor" "profile current"; do
    # shellcheck disable=SC2086  # the word list is the command
    wrapper $stale_cmd
    check "'$stale_cmd' still runs with a stale setting.profile" has_text "no longer exists" "$OUT"
    check_not "'$stale_cmd' is not refused as an unknown profile" has_text "Unknown profile" "$OUT"
done
wrapper profile current --name
assert_eq "$(printf '%s\n' "$OUT" | tail -n 1)" default "the stale default falls back to the default profile"
wrapper profile use default
assert_eq "$RC" 0 "the user can repair it from the command line"
wrapper profiles
check_not "…and the warning is gone" has_text "no longer exists" "$OUT"
CLAUDE_DOCKERIZED_PROFILE=gone wrapper profiles
check_not "an explicit unknown profile is still an error" [ "$RC" -eq 0 ]

t_summary
