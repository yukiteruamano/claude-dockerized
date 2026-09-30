#!/bin/bash
# Config parsing and validator contract (lib/config-lib.sh): INI edge cases,
# policy modes end-to-end into the docker args, container-name sanitizing,
# env-file variable names and the shared model-name rule.
#
# Usage: bash tests/config-parse.test.sh
# shellcheck disable=SC2034,SC2088,SC2317  # globals feed config-lib.sh; literal ~ is config text; helpers run via check/gap

# No `set -u`: config-lib.sh is sourced by callers that do not use it.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="config-parse"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export NO_COLOR=1
mkdir -p "$CONFIG_DIR" "$CCODE_HOME"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"

# load_from <printf-format> — writes the config verbatim and parses it.
load_from() {
    # shellcheck disable=SC2059  # the argument is the file content template
    printf "$1" >"$CONFIG_FILE"
    load_config >/dev/null 2>&1
}

# --- INI edge cases ----------------------------------------------------------------
load_from 'setting.memory=4g\nsetting.cpus=2\n'
assert_eq "$MEMORY" 4g "memory parsed"
assert_eq "$CPUS" 2 "cpus parsed"

load_from 'setting.memory=4g\r\nsetting.cpus=2\r\n'
assert_eq "$MEMORY" 4g "CRLF line endings tolerated (memory)"
assert_eq "$CPUS" 2 "CRLF line endings tolerated (cpus)"

load_from '  setting.model = sonnet  \n# setting.model=opus\n'
assert_eq "$CLAUDE_MODEL" sonnet "whitespace trimmed and comments skipped"

load_from 'setting.model=sonnet\nsetting.model=opus\n'
assert_eq "$CLAUDE_MODEL" opus "the last duplicate key wins"

load_from 'mount.data=~/data:/data\n'
assert_eq "${CUSTOM_MOUNTS[0]:-}" "~/data:/data" "mount value parsed"
assert_eq "${CUSTOM_MOUNT_KEYS[0]:-}" data "mount key parsed"

load_from 'setting.env_file=~/.config/claude-dockerized/a=b\n'
assert_eq "$ENV_FILE" "~/.config/claude-dockerized/a=b" "values may contain '='"

load_from 'setting.cleanup_days=abc\nsetting.memory=lots\nsetting.cpus=-1\n'
assert_eq "$CLEANUP_DAYS" 7 "invalid cleanup_days ignored"
assert_eq "$MEMORY" "" "invalid memory ignored"
assert_eq "$CPUS" "" "invalid cpus ignored"

last_line_parsed() {
    printf 'setting.memory=4g' >"$CONFIG_FILE"
    load_config >/dev/null 2>&1
    [ "$MEMORY" = 4g ]
}
check "CFG-01 last line without a trailing newline is parsed" last_line_parsed

# --- policy modes flow into the container env ----------------------------------------
policy_arg_for() {
    load_from "setting.security_policy=$1\n"
    build_common_docker_args >/dev/null 2>&1
    printf '%s\n' "${DOCKER_COMMON_ARGS[@]}" | grep '^CLAUDE_DOCKERIZED_POLICY='
}
assert_eq "$(policy_arg_for strict)" CLAUDE_DOCKERIZED_POLICY=strict "strict reaches the hooks"
assert_eq "$(policy_arg_for balanced)" CLAUDE_DOCKERIZED_POLICY=balanced "balanced reaches the hooks"
assert_eq "$(policy_arg_for none)" CLAUDE_DOCKERIZED_POLICY=none "none reaches the hooks"
assert_eq "$(policy_arg_for off)" CLAUDE_DOCKERIZED_POLICY=none "off is an alias of none"
assert_eq "$(policy_arg_for yolo)" CLAUDE_DOCKERIZED_POLICY=balanced "invalid policy keeps balanced"

# --- network allowlist -------------------------------------------------------------------
load_from 'setting.network=bridge\n'
assert_eq "$NETWORK" bridge "bridge accepted"
load_from 'setting.network=container:other\n'
assert_eq "$NETWORK" host "container:<id> network refused"

# --- container names --------------------------------------------------------------------
assert_eq "$(sanitize_container_name "my app")" myapp "spaces stripped"
assert_eq "$(sanitize_container_name "--x")" x "leading punctuation stripped"
assert_eq "$(sanitize_container_name '$(id)')" id "shell metacharacters stripped"
assert_eq "$(sanitize_container_name "ñandú")" and "non-ASCII stripped"
assert_eq "$(sanitize_container_name "...")" project "empty result falls back"
is_hex8() { [[ "$1" =~ ^[0-9a-f]{8}$ ]]; }
check "random suffix is 8 hex chars" is_hex8 "$(generate_random_suffix)"
check "random suffixes differ" [ "$(generate_random_suffix)" != "$(generate_random_suffix)" ]

# --- container path ------------------------------------------------------------------------
assert_eq "$(compute_container_path "$HOME/projects/app")" /projects/app "home prefix stripped"
assert_eq "$(compute_container_path /opt/app)" /opt/app "paths outside home unchanged"

# --- env file variable names -----------------------------------------------------------------
envf="$CONFIG_DIR/env"
upsert_ok() { env_file_upsert "$envf" "$1" "$2" >/dev/null 2>&1; }
check "uppercase name accepted" upsert_ok API_TOKEN x
for bad in lower 1LEADING "" "A-B" "A B" 'A$B'; do
    check_not "variable name '$bad' refused" upsert_ok "$bad" x
done
check_not "multi-line value refused" upsert_ok MULTI $'a\nb'
assert_eq "$(stat -c '%a' "$envf")" 600 "env file created 0600"
upsert_ok API_TOKEN y
assert_eq "$(grep -c '^API_TOKEN=' "$envf")" 1 "upsert replaces instead of duplicating"

# --- one model-name rule for the config parser and the wizard ------------------------------
model_from_config() {
    load_from "setting.model=$1\n"
    [ "$CLAUDE_MODEL" = "$1" ]
}
model_from_prompt() {
    CLAUDE_MODEL=""
    prompt_model <<<"$1" >/dev/null 2>&1
    [ "$CLAUDE_MODEL" = "$1" ]
}
for model in sonnet opus claude-opus-5-5 "claude-sonnet-5-5[1m]" 'x"; rm' "a b" "a/b"; do
    cfg=false
    prompt=false
    model_from_config "$model" && cfg=true
    model_from_prompt "$model" && prompt=true
    assert_eq "$prompt" "$cfg" "config and wizard agree on model '$model'"
done
check_not "a model with a quote never reaches settings.json" model_from_config 'x"y'

# --- private temp dir (T-17) ------------------------------------------------------------
tmpdir_for() {
    (
        unset TMPDIR
        XDG_RUNTIME_DIR="$1"
        ensure_private_tmpdir
        printf '%s' "$TMPDIR"
    )
}
assert_eq "$(tmpdir_for "")" "$CONFIG_DIR/tmp" "falls back to a dir under CONFIG_DIR"
assert_eq "$(stat -c '%a' "$CONFIG_DIR/tmp")" 700 "private temp dir is 0700"
mkdir -p "$TMP/runtime"
assert_eq "$(tmpdir_for "$TMP/runtime")" "$TMP/runtime/claude-dockerized" "prefers XDG_RUNTIME_DIR"
assert_eq "$(TMPDIR=/somewhere bash -c 'source "$1/lib/config-lib.sh"; ensure_private_tmpdir; printf %s "$TMPDIR"' _ "$REPO_DIR")" /somewhere "an explicit TMPDIR is kept"
mkdir -p "$TMP/elsewhere"
mkdir -p "$TMP/runtime2"
ln -s "$TMP/elsewhere" "$TMP/runtime2/claude-dockerized"
rm -rf "$CONFIG_DIR/tmp"
ln -s "$TMP/elsewhere" "$CONFIG_DIR/tmp"
assert_eq "$(tmpdir_for "$TMP/runtime2")" /tmp "a planted symlink is never used"
check "the private default is not the shared /tmp/claude" [ "$(grep -c 'TMPDIR:-/tmp/claude' "$REPO_DIR/bin/claude-dockerized" "$REPO_DIR/lib/install-lib.sh" | awk -F: '{s+=$2} END {print s}')" = 0 ]

# --- command-override seams are test-only ------------------------------------------------
seam_value() {
    (
        GPG_AGENT_PROBE_CMD="touch /tmp/should-not-run"
        CLAUDE_DOCKERIZED_TEST_HOOKS="$1"
        test_seam GPG_AGENT_PROBE_CMD
    )
}
assert_eq "$(seam_value "")" "" "seams ignored without the test opt-in"
assert_eq "$(seam_value 1)" "touch /tmp/should-not-run" "seams honored with the test opt-in"

t_summary
